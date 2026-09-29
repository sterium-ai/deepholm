class_name SaveIO
extends RefCounted

## File boundary for the versioned StateCodec dictionary. The candidate is
## written and independently read back before the active path is replaced.

const FORMAT := "deepholm-save-v1"
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const SaveMigrationsType = preload("res://scripts/core/persistence/save_migrations.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const WorldGeneratorType = preload("res://scripts/core/worldgen/world_generator.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const SCHEMA_VERSION := StateCodecType.SCHEMA_VERSION
## Entity kind -> the component fields that kind must carry on the wire
## (F5, issue #294; game-state.schema.json's per-kind if/then). Mirrors what
## ActorTable.spawn() builds from content/actors.json: a colonist's legacy
## worker/needs shape, a wolf's needs/combat/wild, a trader's inventory/visitor.
const ENTITY_COMPONENT_FIELDS := {
	"colonist": ["needs", "needsAccumulator", "labourTable", "work", "hands"],
	"wolf": ["needs", "needsAccumulator", "combat", "wild"],
	"trader": ["inventory", "visitor"],
}

## Full JSON number grammar (RFC 8259), used to capture the complete numeric
## token for the seed/rng fields rather than a bare `-?\d+` prefix -- a
## prefix match on "1e3" or "1.5" would stop at the leading digit and silently
## misread the value (round 2 review).
const _JSON_NUMBER_PATTERN := "-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?"
const _INT64_MAX_DIGITS := "9223372036854775807"
const _INT64_MIN_MAGNITUDE_DIGITS := "9223372036854775808"

static func write_atomic(path: String, state: Dictionary, before_rename: Callable = Callable(), after_temp_write: Callable = Callable()) -> Dictionary:
	var file_name := path.get_file()
	var temporary := path + ".tmp"
	var validation := _validate_state(state)
	if not validation["ok"]:
		_remove_temporary(temporary)
		return _error(validation["code"], validation["message"], path)

	# The wire body keeps rng.seed/state as real JSON integers, matching the
	# schema. JSON.parse_string returns every number as a float, so exact
	# 64-bit fidelity for these two fields is recovered on read by rescanning
	# the raw text instead of trusting the parsed Variant (_restore_exact_rng).
	var json_safe: Dictionary = state.duplicate(true)
	var body := JSON.stringify(json_safe)
	# JSON.parse_string always returns numbers as floats, so a hash taken over
	# the pre-parse dict (real ints) can never match one taken over the
	# parsed-back dict on read. Hash the round-tripped form here so both sides
	# hash the same representation.
	var round_tripped = JSON.parse_string(body)
	var hash := _sha256(JSON.stringify(round_tripped).to_utf8_buffer())
	var envelope := {"format": FORMAT, "integrity": hash, "state": json_safe}
	var encoded := JSON.stringify(envelope)
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		_remove_temporary(temporary)
		return _error("write_failed", "could not open temporary save", path)
	file.store_string(encoded)
	# Force the buffered write to disk (and surface any disk-full/IO error)
	# while the handle is still open. Closing performs its own final flush,
	# which can itself fail (e.g. disk fills between the explicit flush and
	# close), so the error state is captured on both sides of close() rather
	# than trusting the pre-close flush alone.
	file.flush()
	var flush_error := file.get_error()
	file.close()
	var close_error := file.get_error()
	if flush_error != OK or close_error != OK:
		_remove_temporary(temporary)
		var failing_error := close_error if close_error != OK else flush_error
		return _error("write_failed", "could not write temporary save (error %s)" % failing_error, path)

	# Test-only seam: lets acceptance tests simulate a crash that leaves the
	# candidate for this exact target truncated/corrupted on disk, right where
	# the read-back verification below must catch it before target is touched.
	if after_temp_write.is_valid():
		after_temp_write.call(temporary)

	# Re-open the bytes written to the candidate. This catches truncation and
	# serialization/storage failures before the target is considered replaceable.
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
	var parsed = JSON.parse_string(text)
	if parsed == null or not (parsed is Dictionary):
		return {"ok": false, "code": "parse_error", "message": "save JSON is unparseable or truncated", "file": path}
	var envelope: Dictionary = parsed
	if envelope.get("format") != FORMAT or not envelope.has("integrity") or not envelope.has("state"):
		return {"ok": false, "code": "invalid_envelope", "message": "save envelope is missing or invalid", "file": path}
	var state = envelope["state"]
	if not (state is Dictionary):
		return {"ok": false, "code": "schema_error", "message": "save state is not an object", "file": path}
	# Inspect the version before checking the body hash. A newer producer must
	# receive the distinct version error even when its hash uses fields this
	# reader cannot interpret (the reader never returns that state).
	var stored_state_hash := _sha256(JSON.stringify(state).to_utf8_buffer())
	# JSON.parse_string returns all JSON numbers as floats. Normalize the
	# schema's integer fields before type checks, while retaining the hash of the
	# exact wire representation above for integrity verification.
	_coerce_ints(state)
	# Structurally locate the envelope's "state" object once (not per field --
	# both restores below share this single scan of the raw wire text rather
	# than each re-parsing it).
	var located_state := _locate_state_object(text)
	var rng_restore := _restore_exact_rng(state, located_state)
	var seed_restore := _restore_exact_seed(state, located_state)
	var incident_rng_restore := _restore_exact_incident_rng(state, located_state)
	var dig_find_rng_restore := _restore_exact_dig_find_rng(state, located_state)
	var version_value = state.get("schemaVersion")
	if _is_int(version_value) and int(version_value) > SCHEMA_VERSION:
		return {"ok": false, "code": "save_from_newer_version", "message": "save schema is newer than this build", "file": path}
	if str(envelope["integrity"]) != stored_state_hash:
		return {"ok": false, "code": "integrity_mismatch", "message": "save integrity hash does not match", "file": path}
	# Checked only once the save is confirmed to belong to this build and to
	# match its own integrity hash: a fractional or out-of-int64-range
	# seed/rng token is a schema violation, not a newer-version or
	# tampered-file signal, and must never be silently truncated into a
	# plausible-looking (but wrong) integer (round 2 review).
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
	# The schema/integrity checks above only require a non-empty string
	# (_validate_state, run once below); this compares it against the content
	# bundle actually on disk right now (docs/architecture/foundation-for-
	# breadth.md F1). A save written under a since-renamed content bundle gets
	# one chance to be repaired by a registered content-rename entry
	# (save_migrations.gd) before it is rejected -- never silently accepted
	# with a stale id. Resolved BEFORE migrate_legacy_build_jobs() below
	# (round 2 review, issue #449): a legacy job's own retired "buildKind"
	# field is itself a content id (e.g. "wall"), and migrate_legacy_build_jobs()
	# looks that id up against the CURRENT content bundle to synthesize a
	# site's requiredMaterials/buildTicks -- resolving the rename first is
	# what lets that lookup ever find the renamed entry, instead of silently
	# falling back to an empty-cost, one-tick site for a content id the
	# current bundle no longer has.
	# A missing or wrong-typed "contentVersion" is left completely alone here
	# -- never coerced through String() first -- so it reaches
	# _validate_state() below exactly as malformed as it arrived and gets its
	# own "missing required field"/"invalid contentVersion" error, rather than
	# a misleading content_version_mismatch (round 2 review).
	var current_content_version := StateCodecType.content_version()
	var content_version_value = state.get("contentVersion")
	if content_version_value is String and String(content_version_value) != current_content_version:
		var resolved := SaveMigrationsType.resolve_content_version(state, current_content_version)
		if not resolved.get("ok", false):
			return {"ok": false, "code": "content_version_mismatch",
				"message": "save content version '%s' does not match current content version '%s'" % [content_version_value, current_content_version],
				"file": path}
		state = resolved["state"]
	# Issue #406 round-4 review: applied unconditionally (not only inside the
	# schemaVersion-migration branch above), since a legacy "build" job could
	# have been written at ANY prior schemaVersion, including the current one
	# -- construction sites were added without bumping SCHEMA_VERSION (see
	# SaveMigrations.migrate_legacy_build_jobs()'s own doc comment). Runs
	# after the content-rename resolution above and before validation, which
	# only ever has to know about the current "site_fetch"/"site_work" wire
	# shape and current content ids as a result.
	state = SaveMigrationsType.migrate_legacy_build_jobs(state)
	var validation := _validate_state(state)
	if not validation["ok"]:
		return {"ok": false, "code": validation["code"], "message": validation["message"], "file": path}
	return {"ok": true, "state": state}

static func _coerce_ints(state: Dictionary) -> void:
	# The schema declares no floating-point fields anywhere in the tree, so any
	# whole-number float produced by the JSON round trip is really an integer.
	# Walk the full structure generically instead of enumerating every nested
	# path by hand, which is easy to miss (e.g. scheduling.waiting entries).
	# rng.seed/state get a precise fixup afterward via _restore_exact_rng.
	_coerce_floats_to_ints(state)

## JSON.parse_string always converts numbers to float, which cannot hold a
## 64-bit RandomNumberGenerator seed/state exactly. Recover the precise value
## by locating the STRUCTURAL position of "rng"."seed"/"state" inside the
## already-located "state" object (`located_state`, built once by
## _locate_state_object()) and reading the complete raw JSON number token at
## that exact span -- not by text-searching the whole file, which cannot
## distinguish an object boundary from a same-named key elsewhere in the
## envelope, and cannot decode a key written with a JSON \uXXXX escape
## (round 3 review). Returns {"ok": false} -- never a silent fall back to the
## lossy float-derived value already sitting in `state` -- when a token is
## fractional, exceeds the signed 64-bit range, or cannot be structurally
## located at all despite the parsed Variant claiming the field exists.
static func _restore_exact_rng(state: Dictionary, located_state: Dictionary) -> Dictionary:
	if not (state.get("rng") is Dictionary):
		return {"ok": true}
	var rng: Dictionary = state["rng"]
	if not rng.has("seed") and not rng.has("state"):
		return {"ok": true}
	if not located_state.get("ok", false) or not (located_state["members"] as Dictionary).has("rng"):
		return {"ok": false, "message": "rng could not be structurally located in the save's raw JSON"}
	var rng_span: Dictionary = (located_state["members"] as Dictionary)["rng"]
	var text: String = located_state["text"]
	var rng_start: int = rng_span["start"]
	if rng_start >= text.length() or text[rng_start] != "{":
		return {"ok": false, "message": "rng is not an object in the save's raw JSON"}
	var rng_members := _scan_object_members(text, rng_start + 1)
	if not rng_members.has("__end__"):
		return {"ok": false, "message": "rng object could not be structurally parsed from the save's raw JSON"}
	for key in ["seed", "state"]:
		if not rng.has(key):
			continue
		if not rng_members.has(key):
			return {"ok": false, "message": "rng.%s could not be structurally located in the save's raw JSON" % key}
		var span: Dictionary = rng_members[key]
		var token := text.substr(span["start"], span["end"] - span["start"])
		var parsed := _parse_json_integer_token(token)
		if not parsed["ok"]:
			return {"ok": false, "message": "rng.%s is not a supported 64-bit integer" % key}
		rng[key] = parsed["value"]
	return {"ok": true}

## Mirrors _restore_exact_rng() for "incidentScheduler"."rng"."seed"/"state"
## (#295): IncidentScheduler's own independent RandomNumberGenerator snapshot
## is exactly as vulnerable to JSON's lossy float round trip as world's own
## "rng" is -- its .state is an engine-internal 64-bit counter that can
## easily exceed 2^53 regardless of how small the seed is. One extra
## structural descent (state -> incidentScheduler -> rng) versus
## _restore_exact_rng()'s state -> rng, since this field nests one level
## deeper than the top-level "rng" object.
static func _restore_exact_incident_rng(state: Dictionary, located_state: Dictionary) -> Dictionary:
	if not (state.get("incidentScheduler") is Dictionary):
		return {"ok": true}
	var incident_scheduler: Dictionary = state["incidentScheduler"]
	if not (incident_scheduler.get("rng") is Dictionary):
		return {"ok": true}
	var rng: Dictionary = incident_scheduler["rng"]
	if not rng.has("seed") and not rng.has("state"):
		return {"ok": true}
	if not located_state.get("ok", false) or not (located_state["members"] as Dictionary).has("incidentScheduler"):
		return {"ok": false, "message": "incidentScheduler could not be structurally located in the save's raw JSON"}
	var text: String = located_state["text"]
	var incident_span: Dictionary = (located_state["members"] as Dictionary)["incidentScheduler"]
	var incident_start: int = incident_span["start"]
	if incident_start >= text.length() or text[incident_start] != "{":
		return {"ok": false, "message": "incidentScheduler is not an object in the save's raw JSON"}
	var incident_members := _scan_object_members(text, incident_start + 1)
	if not incident_members.has("__end__") or not incident_members.has("rng"):
		return {"ok": false, "message": "incidentScheduler.rng could not be structurally located in the save's raw JSON"}
	var rng_span: Dictionary = incident_members["rng"]
	var rng_start: int = rng_span["start"]
	if rng_start >= text.length() or text[rng_start] != "{":
		return {"ok": false, "message": "incidentScheduler.rng is not an object in the save's raw JSON"}
	var rng_members := _scan_object_members(text, rng_start + 1)
	if not rng_members.has("__end__"):
		return {"ok": false, "message": "incidentScheduler.rng object could not be structurally parsed from the save's raw JSON"}
	for key in ["seed", "state"]:
		if not rng.has(key):
			continue
		if not rng_members.has(key):
			return {"ok": false, "message": "incidentScheduler.rng.%s could not be structurally located in the save's raw JSON" % key}
		var span: Dictionary = rng_members[key]
		var token := text.substr(span["start"], span["end"] - span["start"])
		var parsed := _parse_json_integer_token(token)
		if not parsed["ok"]:
			return {"ok": false, "message": "incidentScheduler.rng.%s is not a supported 64-bit integer" % key}
		rng[key] = parsed["value"]
	return {"ok": true}

## Mirrors _restore_exact_rng() for the top-level "digFindRng"."seed"/"state"
## (ADR 025 round 2 review): world._dig_find_random's own continuation is
## exactly as vulnerable to JSON's lossy float round trip as "rng" is. Same
## nesting depth as _restore_exact_rng() (state -> digFindRng), just a
## different top-level key; optional throughout since this field itself is
## optional on the wire (see _validate_state()'s own comment).
static func _restore_exact_dig_find_rng(state: Dictionary, located_state: Dictionary) -> Dictionary:
	if not (state.get("digFindRng") is Dictionary):
		return {"ok": true}
	var rng: Dictionary = state["digFindRng"]
	if not rng.has("seed") and not rng.has("state"):
		return {"ok": true}
	if not located_state.get("ok", false) or not (located_state["members"] as Dictionary).has("digFindRng"):
		return {"ok": false, "message": "digFindRng could not be structurally located in the save's raw JSON"}
	var rng_span: Dictionary = (located_state["members"] as Dictionary)["digFindRng"]
	var text: String = located_state["text"]
	var rng_start: int = rng_span["start"]
	if rng_start >= text.length() or text[rng_start] != "{":
		return {"ok": false, "message": "digFindRng is not an object in the save's raw JSON"}
	var rng_members := _scan_object_members(text, rng_start + 1)
	if not rng_members.has("__end__"):
		return {"ok": false, "message": "digFindRng object could not be structurally parsed from the save's raw JSON"}
	for key in ["seed", "state"]:
		if not rng.has(key):
			continue
		if not rng_members.has(key):
			return {"ok": false, "message": "digFindRng.%s could not be structurally located in the save's raw JSON" % key}
		var span: Dictionary = rng_members[key]
		var token := text.substr(span["start"], span["end"] - span["start"])
		var parsed := _parse_json_integer_token(token)
		if not parsed["ok"]:
			return {"ok": false, "message": "digFindRng.%s is not a supported 64-bit integer" % key}
		rng[key] = parsed["value"]
	return {"ok": true}

## Mirrors _restore_exact_rng() for the top-level "seed" field (round 1
## review): a seed near or beyond 2^53 loses precision through the ordinary
## float round trip JSON.parse_string() performs, same as rng.seed/state did.
## Reads the *direct* "seed" member of the "state" object located by
## _locate_state_object() -- `_scan_object_members()` only ever descends one
## level per call, so this can never be confused by "rng"'s own nested
## "seed" key (which lives one level deeper, inside "rng"'s own member scan,
## never surfacing in `state`'s direct member list) or by a same-named field
## on the envelope itself (outside "state" entirely, never scanned here).
## Returns {"ok": false} -- never a silent fall back to the lossy
## float-derived value -- for a fractional or out-of-64-bit-range token, or
## when the field cannot be structurally located at all (round 2/3 review).
static func _restore_exact_seed(state: Dictionary, located_state: Dictionary) -> Dictionary:
	if not state.has("seed"):
		return {"ok": true}
	if not located_state.get("ok", false) or not (located_state["members"] as Dictionary).has("seed"):
		return {"ok": false, "message": "seed could not be structurally located in the save's raw JSON"}
	var span: Dictionary = (located_state["members"] as Dictionary)["seed"]
	var text: String = located_state["text"]
	var token := text.substr(span["start"], span["end"] - span["start"])
	var parsed := _parse_json_integer_token(token)
	if not parsed["ok"]:
		return {"ok": false, "message": "seed is not a supported 64-bit integer"}
	state["seed"] = parsed["value"]
	return {"ok": true}

## Structurally locates the envelope's top-level "state" object and returns
## the *direct* (one level deep) members of that object -- each mapped to the
## raw text span of its still-unparsed value -- so callers can read the exact
## on-disk spelling of a specific field's number token without ever treating
## a substring match anywhere else in the file as if it were that field.
## Decodes JSON string escapes (including \uXXXX) while scanning key names,
## so an escaped key spells the same field a plain one would (round 3
## review). Returns {"ok": false} if the envelope or "state" is malformed --
## this should never happen for text that already parsed successfully via
## JSON.parse_string, but a caller must fail closed rather than silently
## falling back to a lossy value if it somehow does.
static func _locate_state_object(text: String) -> Dictionary:
	var pos := _skip_ws(text, 0)
	if pos >= text.length() or text[pos] != "{":
		return {"ok": false}
	var root_members := _scan_object_members(text, pos + 1)
	if not root_members.has("__end__") or not root_members.has("state"):
		return {"ok": false}
	var state_span: Dictionary = root_members["state"]
	var state_start: int = state_span["start"]
	if state_start >= text.length() or text[state_start] != "{":
		return {"ok": false}
	var state_members := _scan_object_members(text, state_start + 1)
	if not state_members.has("__end__"):
		return {"ok": false}
	return {"ok": true, "members": state_members, "text": text}

## Parses a JSON object's *direct* members, starting at `pos` (the position
## right after the object's opening `{`). Returns a Dictionary from each
## decoded key to {"start": int, "end": int}: the raw text span of that
## member's still-unparsed value (a number's span is exactly its complete
## token text; an object/array/string's span covers its own delimiters).
## Never recurses into a nested object/array's own members -- a caller that
## needs those calls this again with that value's own span. A duplicate key
## keeps the LAST occurrence, matching JSON.parse_string's own dictionary
## build (repeated key overwrites). The returned Dictionary's "__end__" entry
## (never a valid JSON key, so it cannot collide with a real member) holds
## the position right after the object's closing `}`; its absence means the
## text was not a well-formed object starting at `pos`.
static func _scan_object_members(text: String, pos: int) -> Dictionary:
	var members := {}
	pos = _skip_ws(text, pos)
	if pos >= text.length():
		return members
	if text[pos] == "}":
		members["__end__"] = pos + 1
		return members
	while true:
		pos = _skip_ws(text, pos)
		if pos >= text.length() or text[pos] != "\"":
			return {}
		var key_result := _parse_json_string(text, pos)
		if not key_result["ok"]:
			return {}
		var key: String = key_result["value"]
		pos = _skip_ws(text, key_result["end"])
		if pos >= text.length() or text[pos] != ":":
			return {}
		pos = _skip_ws(text, pos + 1)
		var value_start := pos
		var value_end := _skip_json_value(text, pos)
		if value_end < 0:
			return {}
		members[key] = {"start": value_start, "end": value_end}
		pos = _skip_ws(text, value_end)
		if pos >= text.length():
			return {}
		if text[pos] == ",":
			pos += 1
			continue
		if text[pos] == "}":
			members["__end__"] = pos + 1
			return members
		return {}
	return {} # unreachable; satisfies the static analyzer's return-path check

## Lazily-compiled, cached once per class load: a save's "state" object can
## carry tens of thousands of number tokens (e.g. a 256x256 map's own
## coordinate/id fields), and RegEx.compile() is not cheap -- compiling it
## fresh on every single token turned every save read into an O(field count)
## series of regex compiles, not just an O(text length) scan.
static var _number_regex: RegEx = null

static func _get_number_regex() -> RegEx:
	if _number_regex == null:
		_number_regex = RegEx.new()
		_number_regex.compile(_JSON_NUMBER_PATTERN)
	return _number_regex

## Returns the position right after the complete JSON value starting at
## `pos` (string, number, object, array, true, false, or null), or -1 if
## `pos` does not begin a well-formed value. Used only to skip past a
## member's value while scanning for sibling keys -- the caller that actually
## wants "state"'s or "rng"'s own direct members calls _scan_object_members()
## directly with that object's own span, never through here. Skips string and
## nested-object content without decoding or mapping it (`_skip_json_string()`/
## `_skip_json_object()`) -- a value being skipped is never inspected, so
## building its decoded text or member map, only to immediately discard it,
## would be pure waste over a large save (a 256x256 map's 65536-entry
## `tiles` array, its route-search `visited`/`frontier` tile lists, etc.).
static func _skip_json_value(text: String, pos: int) -> int:
	pos = _skip_ws(text, pos)
	if pos >= text.length():
		return -1
	var c := text[pos]
	if c == "\"":
		return _skip_json_string(text, pos)
	if c == "{":
		return _skip_json_object(text, pos + 1)
	if c == "[":
		return _skip_json_array(text, pos + 1)
	if text.substr(pos, 4) == "true":
		return pos + 4
	if text.substr(pos, 5) == "false":
		return pos + 5
	if text.substr(pos, 4) == "null":
		return pos + 4
	var num_match := _get_number_regex().search(text, pos)
	if num_match == null or num_match.get_start() != pos:
		return -1
	return num_match.get_end()

## Returns the position right after the JSON object starting at `pos` (the
## position right after the object's opening `{`), or -1 if malformed --
## mirrors _scan_object_members() but never decodes a key or builds a member
## map, since a sibling value being skipped is never inspected (only used by
## _skip_json_value() for a nested object it is skipping over, never for
## "state" or "rng" themselves).
static func _skip_json_object(text: String, pos: int) -> int:
	pos = _skip_ws(text, pos)
	if pos >= text.length():
		return -1
	if text[pos] == "}":
		return pos + 1
	while true:
		pos = _skip_ws(text, pos)
		if pos >= text.length() or text[pos] != "\"":
			return -1
		var key_end := _skip_json_string(text, pos)
		if key_end < 0:
			return -1
		pos = _skip_ws(text, key_end)
		if pos >= text.length() or text[pos] != ":":
			return -1
		pos = _skip_ws(text, pos + 1)
		var value_end := _skip_json_value(text, pos)
		if value_end < 0:
			return -1
		pos = _skip_ws(text, value_end)
		if pos >= text.length():
			return -1
		if text[pos] == ",":
			pos += 1
			continue
		if text[pos] == "}":
			return pos + 1
		return -1
	return -1 # unreachable; satisfies the static analyzer's return-path check

## Returns the position right after the JSON string literal starting at
## `pos` (which must be `"`), or -1 if unterminated -- unlike
## _parse_json_string(), never builds the decoded value, since a value being
## skipped (as opposed to a key being matched against "seed"/"rng"/"state")
## is never inspected.
static func _skip_json_string(text: String, pos: int) -> int:
	if pos >= text.length() or text[pos] != "\"":
		return -1
	var i := pos + 1
	var length := text.length()
	while i < length:
		var c := text[i]
		if c == "\"":
			return i + 1
		if c == "\\":
			i += 2
			continue
		i += 1
	return -1

## Returns the position right after the JSON array starting at `pos` (the
## position right after the array's opening `[`), or -1 if malformed.
static func _skip_json_array(text: String, pos: int) -> int:
	pos = _skip_ws(text, pos)
	if pos >= text.length():
		return -1
	if text[pos] == "]":
		return pos + 1
	while true:
		var value_end := _skip_json_value(text, pos)
		if value_end < 0:
			return -1
		pos = _skip_ws(text, value_end)
		if pos >= text.length():
			return -1
		if text[pos] == ",":
			pos = _skip_ws(text, pos + 1)
			continue
		if text[pos] == "]":
			return pos + 1
		return -1
	return -1 # unreachable; satisfies the static analyzer's return-path check

## Decodes one JSON string literal starting at `pos` (which must be `"`),
## resolving backslash escapes -- including `\uXXXX` -- so an escaped key
## (e.g. "seed") decodes to the identical string a plain one would
## ("seed"), matching what JSON.parse_string() itself already does when it
## builds the parsed Dictionary's keys (round 3 review). Returns
## {"ok": false} for an unterminated or malformed literal.
static func _parse_json_string(text: String, pos: int) -> Dictionary:
	if pos >= text.length() or text[pos] != "\"":
		return {"ok": false}
	var i := pos + 1
	var out := ""
	while i < text.length():
		var c := text[i]
		if c == "\"":
			return {"ok": true, "value": out, "end": i + 1}
		if c == "\\":
			i += 1
			if i >= text.length():
				return {"ok": false}
			var esc := text[i]
			match esc:
				"\"":
					out += "\""
				"\\":
					out += "\\"
				"/":
					out += "/"
				"b":
					out += char(0x08)
				"f":
					out += char(0x0C)
				"n":
					out += "\n"
				"r":
					out += "\r"
				"t":
					out += "\t"
				"u":
					if i + 4 >= text.length():
						return {"ok": false}
					var hex := text.substr(i + 1, 4)
					if not hex.is_valid_hex_number(false):
						return {"ok": false}
					out += char(hex.hex_to_int())
					i += 4
				_:
					return {"ok": false}
			i += 1
		else:
			out += c
			i += 1
	return {"ok": false}

static func _skip_ws(text: String, pos: int) -> int:
	while pos < text.length() and (text[pos] == " " or text[pos] == "\t" or text[pos] == "\n" or text[pos] == "\r"):
		pos += 1
	return pos

## Decomposes one complete JSON number token (as matched by _JSON_NUMBER_PATTERN)
## into its exact integer value when the token denotes a mathematically whole
## number that fits in a signed 64-bit integer -- JSON gives "1000", "1e3" and
## "1000.0" the identical meaning regardless of surface form, so all three
## restore to the same exact int. Returns {"ok": false} for a token with a
## genuine (non-zero) fractional remainder, or one whose magnitude exceeds
## int64, rather than truncating or overflowing it into a plausible-looking
## wrong value (round 2 review).
static func _parse_json_integer_token(token: String) -> Dictionary:
	var pattern := RegEx.new()
	pattern.compile("^(-)?(0|[1-9][0-9]*)(?:\\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$")
	var m := pattern.search(token)
	if m == null:
		return {"ok": false}
	var negative := m.get_string(1) == "-"
	var int_part := m.get_string(2)
	var frac_digits := m.get_string(3)
	var exp_group := m.get_string(4)

	var digits := int_part + frac_digits
	var mantissa_is_zero := digits.lstrip("0") == ""

	# Zero times any power of ten is exactly zero, independent of the
	# exponent's magnitude or sign -- "0", "-0", "0.0e21" and "0e999999999999"
	# all denote the same integer 0. Deciding this before any exponent
	# magnitude/padding logic keeps a zero mantissa from ever being rejected
	# by the padding-length guard below (round 4 review).
	if mantissa_is_zero:
		return {"ok": true, "value": 0}

	# A short token can spell an arbitrarily long exponent (e.g.
	# "1e999999999999999999999999"). Converting that many digits with
	# to_int() can itself overflow/wrap before the value is ever used, and no
	# legitimate in-range int64 needs an exponent whose significant digit
	# count exceeds a handful of digits -- so a longer one is decided here,
	# without ever computing its exact numeric value (round 3 review).
	var exponent := 0
	if not exp_group.is_empty():
		var exp_negative := exp_group.begins_with("-")
		var exp_significant := exp_group.lstrip("+-").lstrip("0")
		if exp_significant.length() > 6:
			return {"ok": false}
		exponent = exp_significant.to_int()
		if exp_negative:
			exponent = -exponent

	var point := int_part.length() + exponent
	if point < 0:
		if not mantissa_is_zero:
			return {"ok": false}
		digits = "0"
	elif point < digits.length():
		var fraction := digits.substr(point)
		if fraction.lstrip("0") != "":
			return {"ok": false}
		digits = digits.substr(0, point)
	else:
		var pad := point - digits.length()
		# Any padded length beyond int64's own maximum digit count is
		# unconditionally out of range; reject before ever allocating the
		# padded string, so a short token can never request unbounded work
		# here either (round 3 review).
		if pad > _INT64_MAX_DIGITS.length():
			return {"ok": false}
		digits += "0".repeat(pad)

	digits = digits.lstrip("0")
	if digits == "":
		digits = "0"

	if negative:
		if digits.length() > _INT64_MIN_MAGNITUDE_DIGITS.length() or (digits.length() == _INT64_MIN_MAGNITUDE_DIGITS.length() and digits > _INT64_MIN_MAGNITUDE_DIGITS):
			return {"ok": false}
		if digits == _INT64_MIN_MAGNITUDE_DIGITS:
			return {"ok": true, "value": -9223372036854775807 - 1}
		return {"ok": true, "value": -digits.to_int()}
	if digits.length() > _INT64_MAX_DIGITS.length() or (digits.length() == _INT64_MAX_DIGITS.length() and digits > _INT64_MAX_DIGITS):
		return {"ok": false}
	return {"ok": true, "value": digits.to_int()}

static func _coerce_floats_to_ints(value) -> void:
	if value is Dictionary:
		for key in value.keys():
			var entry = value[key]
			if typeof(entry) == TYPE_FLOAT and float(entry) == int(entry):
				value[key] = int(entry)
			elif entry is Dictionary or entry is Array:
				_coerce_floats_to_ints(entry)
	elif value is Array:
		for i in range(value.size()):
			var entry = value[i]
			if typeof(entry) == TYPE_FLOAT and float(entry) == int(entry):
				value[i] = int(entry)
			elif entry is Dictionary or entry is Array:
				_coerce_floats_to_ints(entry)

## Mirrors docs/architecture/contracts/game-state.schema.json field for
## field: every required key, declared type, range, enum, id pattern, and
## additionalProperties:false boundary at every nesting level. A save can
## only pass this after its integrity hash has already been confirmed, so a
## tampered-but-rehashed file still has to satisfy the full nested shape. Per
## simulation-boundaries.md's persistence boundary and ADR 003 principle 3, a
## missing required field returns the migration error code (no_migration_available),
## never schema_error -- only wrong type/range/enum/unexpected-field violations do.
static func _validate_state(state: Dictionary) -> Dictionary:
	var top_level := ["schemaVersion", "contentVersion", "seed", "tick", "epoch", "map", "entities", "inventory", "jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId", "groundBerries", "workProgress", "pausedJobs", "toolItems", "toolReservations", "needJobAssignments", "calendarAlerts", "toolFetchExcluded", "incidentScheduler"]
	# combatBlockedTargets (round-6 review, F5/#302) is optional at this
	# top level, like "health" is on an individual objects entry
	# (_valid_object() below): its absence is allowed for any save written
	# before this task (CombatGiver had no exclusion state to persist yet),
	# so adding it never breaks an existing schemaVersion 21 save the way
	# adding it to `top_level`'s required set would.
	#
	# ADR 025 round 2 review: "digFindRng" (world._dig_find_random's own
	# continuation, StateCodec._encode()) is allowed but deliberately not in
	# top_level's required-fields loop below -- every real save from this
	# build's encode() always carries it, but it stays optional on the wire so
	# an older hand-built fixture that never exercises dig's find roll (schema
	# validation predates this field) still validates; StateCodec.decode()
	# leaves world._dig_find_random at its own fresh constructor seed when absent.
	#
	# rescueVictimAssignments (issue #360 round-3 review finding 1) is optional
	# at this top level for the same reason combatBlockedTargets is: absence is
	# allowed for any save written before rescue existed, so adding it never
	# breaks an existing save the way adding it to top_level's required set
	# would.
	#
	# workProgressOwners (round-5 review, #278/#303): the job_id that owns each
	# workProgress key (StateCodec._encode_work_progress_owners()), optional on
	# the wire for the same reason "digFindRng" is -- an older fixture/save
	# predating this field still validates, and WorldState restores with no
	# owners at all in that case (world_state.gd's own
	# _restore_work_progress_owners() doc comment) rather than guess one.
	# approachRetiredActors: legacy field from issue #390/ADR 031 (superseded by
	# issue #391 -- ApproachGiver no longer retires an actor permanently, see
	# approach_giver.gd's own class doc comment). Kept accepted here, and its
	# own structural validator below kept, purely so a save written before
	# this change still loads; state_codec.gd's decode() no longer reads it.
	# constructionSites (issue #406): optional for the same reason
	# combatBlockedTargets is -- absence is allowed for any save written
	# before construction sites existed.
	var optional_top_level := ["combatBlockedTargets", "digFindRng", "rescueVictimAssignments", "workProgressOwners", "suspendedWorkProgress", "approachJobTargets", "approachRetiredActors", "constructionSites"]
	if not _keys_allowed(state, top_level + optional_top_level):
		return _fail("unexpected top-level field")
	for key in top_level:
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

	if not (state["map"] is Dictionary):
		return _fail("invalid map type")
	var map: Dictionary = state["map"]
	if not _keys_allowed(map, ["width", "height", "tiles", "generatorVersion"]):
		return _fail("unexpected map field")
	for key in ["width", "height", "tiles", "generatorVersion"]:
		if not map.has(key):
			return _fail_missing("missing map field '%s'" % key)
	if not _is_int_min(map.get("width"), 1) or not _is_int_min(map.get("height"), 1):
		return _fail("invalid map dimensions")
	# Restoration preserves a saved map's exact dimensions (state_codec.gd's
	# decode() no longer re-clamps through WorldGenerator.resolve_size(),
	# round 1 review), so a small fixture below the 16-tile new-game minimum
	# is still valid here -- only an upper bound applies, matching the largest
	# size WorldGenerator/WorldState can ever produce or operate on.
	var max_world_size := int(ContentRegistryType.new().document("mapgen").get("max_world_size", WorldGeneratorType.DEFAULT_MAX_WORLD_SIZE))
	if int(map["width"]) > max_world_size or int(map["height"]) > max_world_size:
		return _fail("map dimensions exceed the supported maximum")
	if not _is_int_min(map.get("generatorVersion"), 1):
		return _fail("invalid map generatorVersion")
	if not (map.get("tiles") is Array):
		return _fail("invalid map tiles type")
	for tile in map["tiles"]:
		if not (tile is String) or not ["rock", "soil", "floor", "plowed_soil", "planted", "hazard", "tree", "water", "trench"].has(tile):
			return _fail("invalid map tile")
	var map_width := int(map["width"])
	var map_height := int(map["height"])
	# issue #299: dimensions/tile-count consistency was never checked before
	# this task -- a save whose "tiles" length does not match width*height
	# (a truncated write, a hand-edited file) is now rejected here rather
	# than accepted and later indexed out of bounds.
	if (map["tiles"] as Array).size() != map_width * map_height:
		return _fail("map tiles length does not match width*height")

	var items_check := _valid_items(state.get("items"), map_width, map_height)
	if not items_check["ok"]:
		return items_check

	if not (state["objects"] is Array):
		return _fail("invalid objects type")
	for object_entry in state["objects"]:
		var object_check := _valid_object(object_entry, map_width, map_height)
		if not object_check["ok"]:
			return object_check

	if state.has("constructionSites"):
		if not (state["constructionSites"] is Array):
			return _fail("invalid constructionSites type")
		for site_entry in state["constructionSites"]:
			var site_check := _valid_construction_site(site_entry, map_width, map_height)
			if not site_check["ok"]:
				return site_check

	var zones_check := _valid_zones(state.get("zones"), map_width, map_height)
	if not zones_check["ok"]:
		return zones_check
	if not _is_int_min(state.get("nextZoneId"), 1):
		return _fail("invalid nextZoneId")

	var ground_berries_check := _valid_ground_berries(state.get("groundBerries"), map_width, map_height)
	if not ground_berries_check["ok"]:
		return ground_berries_check

	var work_progress_check := _valid_work_progress(state.get("workProgress"), map_width, map_height)
	if not work_progress_check["ok"]:
		return work_progress_check

	if state.has("workProgressOwners"):
		var work_progress_owners_check := _valid_work_progress_owners(state["workProgressOwners"], map_width, map_height)
		if not work_progress_owners_check["ok"]:
			return work_progress_owners_check

	if state.has("suspendedWorkProgress"):
		var suspended_work_progress_check := _valid_suspended_work_progress(state["suspendedWorkProgress"])
		if not suspended_work_progress_check["ok"]:
			return suspended_work_progress_check

	var paused_jobs_check := _valid_paused_jobs(state.get("pausedJobs"))
	if not paused_jobs_check["ok"]:
		return paused_jobs_check

	var need_job_assignments_check := _valid_need_job_assignments(state.get("needJobAssignments"))
	if not need_job_assignments_check["ok"]:
		return need_job_assignments_check

	if state.has("rescueVictimAssignments"):
		var rescue_victim_assignments_check := _valid_rescue_victim_assignments(state["rescueVictimAssignments"])
		if not rescue_victim_assignments_check["ok"]:
			return rescue_victim_assignments_check

	if state.has("combatBlockedTargets"):
		var combat_blocked_targets_check := _valid_combat_blocked_targets(state["combatBlockedTargets"], map_width, map_height)
		if not combat_blocked_targets_check["ok"]:
			return combat_blocked_targets_check

	if state.has("approachJobTargets"):
		var approach_job_targets_check := _valid_approach_job_targets(state["approachJobTargets"], map_width, map_height)
		if not approach_job_targets_check["ok"]:
			return approach_job_targets_check

	if state.has("approachRetiredActors"):
		var approach_retired_actors_check := _valid_approach_retired_actors(state["approachRetiredActors"])
		if not approach_retired_actors_check["ok"]:
			return approach_retired_actors_check

	var calendar_alerts_check := _valid_calendar_alerts(state.get("calendarAlerts"))
	if not calendar_alerts_check["ok"]:
		return calendar_alerts_check

	var tool_fetch_excluded_check := _valid_tool_fetch_excluded(state.get("toolFetchExcluded"), state.get("toolItems"))
	if not tool_fetch_excluded_check["ok"]:
		return tool_fetch_excluded_check

	var tool_items_check := _valid_tool_items(state.get("toolItems"), map_width, map_height)
	if not tool_items_check["ok"]:
		return tool_items_check

	var tool_reservations_check := _valid_tool_reservations(state.get("toolReservations"), state.get("toolItems"))
	if not tool_reservations_check["ok"]:
		return tool_reservations_check

	if not (state["entities"] is Array):
		return _fail("invalid entities type")
	for entity in state["entities"]:
		if not (entity is Dictionary):
			return _fail("invalid entity type")
		if not _keys_allowed(entity, ["id", "kind", "x", "y", "factionId", "health", "trapped", "needs", "needsAccumulator", "labourTable", "route", "work", "hands", "heldTool", "combat", "inventory", "wild", "visitor"]):
			return _fail("unexpected entity field")
		if (not entity.has("id") or not entity.has("kind") or not entity.has("x") or not entity.has("y")
				or not entity.has("factionId") or not entity.has("health") or not entity.has("route") or not entity.has("trapped")):
			return _fail_missing("missing entity field")
		if not _matches_id_pattern(entity["id"]) or not ENTITY_COMPONENT_FIELDS.has(entity["kind"]):
			return _fail("invalid entity id or kind")
		# F5 (issue #294): each kind requires exactly its own declared component
		# fields (content/actors.json via ActorTable.spawn()), mirroring
		# game-state.schema.json's per-kind if/then -- a wolf/trader never
		# carries a colonist-only default, and a colonist never lacks its own.
		for field in ENTITY_COMPONENT_FIELDS[entity["kind"]]:
			if not entity.has(field):
				return _fail_missing("missing entity field '%s'" % field)
		if (not _is_int_min(entity["x"], 0) or not _is_int_min(entity["y"], 0)
				or int(entity["x"]) >= map_width or int(entity["y"]) >= map_height):
			return _fail("invalid entity position")
		if not _matches_id_pattern(entity["factionId"]):
			return _fail("invalid entity factionId")
		var health_check := _valid_entity_health(entity["health"])
		if not health_check["ok"]:
			return health_check
		if entity.has("needs"):
			var needs = entity["needs"]
			if not (needs is Dictionary):
				return _fail("invalid entity needs type")
			var needs_check := _require_fields(needs, ["food", "water", "rest"], "entity needs")
			if not needs_check["ok"]:
				return needs_check
			for need_key in ["food", "water", "rest"]:
				if not _is_int(needs[need_key]) or int(needs[need_key]) < 0 or int(needs[need_key]) > 100:
					return _fail("invalid entity need '%s'" % need_key)
		if entity.has("needsAccumulator"):
			var accumulator = entity["needsAccumulator"]
			if not (accumulator is Dictionary):
				return _fail("invalid entity needsAccumulator type")
			var accumulator_check := _require_fields(accumulator, ["food", "water", "rest"], "entity needsAccumulator")
			if not accumulator_check["ok"]:
				return accumulator_check
			for need_key in ["food", "water", "rest"]:
				if not _is_int(accumulator[need_key]) or int(accumulator[need_key]) < 0:
					return _fail("invalid entity needsAccumulator '%s'" % need_key)
		if entity.has("labourTable"):
			var labour_table_check := _valid_labour_table(entity["labourTable"])
			if not labour_table_check["ok"]:
				return labour_table_check
		var route_check := _valid_entity_route(entity["route"], map_width, map_height)
		if not route_check["ok"]:
			return route_check
		var trapped_check := _valid_entity_trapped(entity["trapped"], map_width, map_height)
		if not trapped_check["ok"]:
			return trapped_check
		if entity.has("work"):
			var work_check := _valid_entity_work(entity["work"])
			if not work_check["ok"]:
				return work_check
		if entity.has("hands"):
			var hands_check := _valid_entity_hands(entity["hands"])
			if not hands_check["ok"]:
				return hands_check
		if entity.has("heldTool") and (not (entity["heldTool"] is String) or not _matches_optional_id_pattern(entity["heldTool"])):
			return _fail("invalid entity heldTool")
		if entity.has("combat"):
			var combat_check := _valid_entity_combat(entity["combat"])
			if not combat_check["ok"]:
				return combat_check
		if entity.has("inventory"):
			var inventory_check := _valid_entity_inventory(entity["inventory"])
			if not inventory_check["ok"]:
				return inventory_check
		for flag in ["wild", "visitor"]:
			if entity.has(flag) and entity[flag] != true:
				return _fail("invalid entity %s" % flag)

	if not (state["inventory"] is Dictionary):
		return _fail("invalid inventory type")
	for key in state["inventory"].keys():
		if not _matches_id_pattern(key):
			return _fail("invalid inventory key")
		if not _is_int_min(state["inventory"][key], 0):
			return _fail("invalid inventory value")

	if not (state["jobs"] is Array):
		return _fail("invalid jobs type")
	var job_required := ["id", "kind", "status", "priority", "target", "reason", "remedy", "blockingJobId",
		"itemId", "cell", "retryAt", "backoffTicks"]
	# "site" (issue #278/#303, generalized by #406) is deliberately NOT in
	# job_required: every save_schema_v1..v10 fixture predates it, and
	# introducing a real schema migration for one harmless-default field is
	# out of scope here. _keys_allowed() below explicitly permits it alongside
	# job_required, so an old fixture missing it still loads
	# (StateCodec._decode_jobs() already defaults an absent site to null --
	# the same harmless default any non-site-job job carries) and a fresh
	# save -- which always encodes it, unconditionally, via
	# StateCodec._encode_jobs() -- still validates its shape when present.
	# "buildKind" (issue #278/#303) no longer exists as of issue #406: the
	# object kind to place lives on the construction site record itself, not
	# duplicated onto every job working that site.
	var job_optional := ["site"]
	for job in state["jobs"]:
		if not (job is Dictionary):
			return _fail("invalid job type")
		if not _keys_allowed(job, job_required + job_optional):
			return _fail("unexpected job field")
		for key in job_required:
			if not job.has(key):
				return _fail_missing("missing job field '%s'" % key)
		if not _matches_id_pattern(job["id"]):
			return _fail("invalid job id")
		if not (job["kind"] is String) or not ["dig", "site_fetch", "site_work", "craft", "chop", "haul", "forage", "till", "sow", "mine", "eat_food", "drink_water", "sleep", "incident", "escape_trench", "flee", "rescue", "approach"].has(job["kind"]):
			return _fail("invalid job kind")
		if not (job["status"] is String) or not ["queued", "active", "completed", "failed", "cancelled"].has(job["status"]):
			return _fail("invalid job status")
		if not _is_int(job["priority"]) or not [0, 1, 2].has(int(job["priority"])):
			return _fail("invalid job priority")
		var job_target_check := _valid_tile(job["target"], map_width, map_height)
		if not job_target_check["ok"]:
			return job_target_check
		if not (job["reason"] is String) or not (job["remedy"] is String) or not (job["blockingJobId"] is String):
			return _fail("invalid job reason, remedy, or blockingJobId")
		if not (job["itemId"] is String) or not _matches_optional_id_pattern(job["itemId"]):
			return _fail("invalid job itemId")
		if job["cell"] != null:
			var cell_check := _valid_tile(job["cell"], map_width, map_height)
			if not cell_check["ok"]:
				return cell_check
		if not _is_int_min(job["retryAt"], 0) or not _is_int_min(job["backoffTicks"], 0):
			return _fail("invalid job retryAt or backoffTicks")
		if job.get("site") != null:
			var site_check := _valid_tile(job["site"], map_width, map_height)
			if not site_check["ok"]:
				return site_check
		# A site_fetch/site_work job's own site is mandatory, not optional
		# (issue #278/#303 round-2 review, generalized by #406): activation
		# and completion both assume a tile, so a save missing it is rejected
		# here rather than decoded and ticked.
		if String(job["kind"]) in ["site_fetch", "site_work"] and job.get("site") == null:
			return _fail("site job missing site")

	if not (state["scheduling"] is Dictionary):
		return _fail("invalid scheduling type")
	var scheduling: Dictionary = state["scheduling"]
	var scheduling_required := ["nextJobId", "jobSequence", "jobTick", "queueEventSequence", "eventSequence",
		"waiting", "nextOrdinal", "cursors", "pending", "assignments", "activatedEntries"]
	if not _keys_allowed(scheduling, scheduling_required):
		return _fail("unexpected scheduling field")
	for key in scheduling_required:
		if not scheduling.has(key):
			return _fail_missing("missing scheduling field '%s'" % key)
	if not _is_int_min(scheduling["nextJobId"], 1):
		return _fail("invalid scheduling.nextJobId")
	if not _is_int_min(scheduling["jobSequence"], 0):
		return _fail("invalid scheduling.jobSequence")
	if not _is_int_min(scheduling["jobTick"], 0):
		return _fail("invalid scheduling.jobTick")
	if not _is_int_min(scheduling["queueEventSequence"], -1):
		return _fail("invalid scheduling.queueEventSequence")
	if not _is_int_min(scheduling["eventSequence"], 0):
		return _fail("invalid scheduling.eventSequence")
	if not _is_int_min(scheduling["nextOrdinal"], 0):
		return _fail("invalid scheduling.nextOrdinal")
	if not (scheduling["waiting"] is Array):
		return _fail("invalid scheduling.waiting type")
	for entry in scheduling["waiting"]:
		var waiting_check := _valid_queue_entry(entry, map_width, map_height)
		if not waiting_check["ok"]:
			return waiting_check
	if not (scheduling["cursors"] is Dictionary):
		return _fail("invalid scheduling.cursors type")
	for key in scheduling["cursors"].keys():
		if not _is_int_min(scheduling["cursors"][key], 0):
			return _fail("invalid scheduling.cursors value")
	if not (scheduling["pending"] is Dictionary):
		return _fail("invalid scheduling.pending type")
	for key in scheduling["pending"].keys():
		var pending_check := _valid_pending_entry(scheduling["pending"][key], map_width, map_height)
		if not pending_check["ok"]:
			return pending_check
	if not (scheduling["assignments"] is Dictionary):
		return _fail("invalid scheduling.assignments type")
	for key in scheduling["assignments"].keys():
		var assignment_check := _valid_assignment_entry(scheduling["assignments"][key], map_width, map_height)
		if not assignment_check["ok"]:
			return assignment_check
	if not (scheduling["activatedEntries"] is Dictionary):
		return _fail("invalid scheduling.activatedEntries type")
	for key in scheduling["activatedEntries"].keys():
		if not _matches_id_pattern(key):
			return _fail("invalid scheduling.activatedEntries key")
		var activated_entry_check := _valid_queue_entry(scheduling["activatedEntries"][key], map_width, map_height)
		if not activated_entry_check["ok"]:
			return activated_entry_check

	if not (state["rng"] is Dictionary):
		return _fail("invalid rng type")
	var rng: Dictionary = state["rng"]
	if not _keys_allowed(rng, ["seed", "state"]):
		return _fail("unexpected rng field")
	if not rng.has("seed") or not rng.has("state"):
		return _fail_missing("missing rng field")
	if not _is_int(rng["seed"]) or not _is_int(rng["state"]):
		return _fail("invalid rng fields")

	var incident_scheduler_check := _valid_incident_scheduler(state.get("incidentScheduler"))
	if not incident_scheduler_check["ok"]:
		return incident_scheduler_check

	if state.has("digFindRng"):
		var dig_find_rng_check := _valid_dig_find_rng(state["digFindRng"])
		if not dig_find_rng_check["ok"]:
			return dig_find_rng_check

	return {"ok": true}

static func _fail(message: String) -> Dictionary:
	return {"ok": false, "code": "schema_error", "message": message}

## docs/architecture/simulation-boundaries.md's persistence boundary and ADR
## 003 principle 3 both require a missing required field to fail with a
## migration error, never a silent default. Reuse the migration stub's own
## code: from the reader's view a missing field is exactly what a migration
## would need to backfill, and none is available yet.
static func _fail_missing(message: String) -> Dictionary:
	return {"ok": false, "code": "no_migration_available", "message": message}

## Shared shape check for every nested object in the tree: an unexpected key
## is a schema_error (the producer wrote something this schema never
## declared), but ANY absent required key -- at any nesting depth -- is a
## missing-field migration error, never schema_error. Centralizing this here
## is what keeps that rule uniform across every nested validator below,
## instead of re-deciding it per call site.
static func _require_fields(dict: Dictionary, required: Array, label: String) -> Dictionary:
	if not _keys_allowed(dict, required):
		return _fail("unexpected %s field" % label)
	for key in required:
		if not dict.has(key):
			return _fail_missing("missing %s field '%s'" % [label, key])
	return {"ok": true}

static func _keys_allowed(dict: Dictionary, allowed: Array) -> bool:
	for key in dict.keys():
		if not allowed.has(key):
			return false
	return true

static func _is_int(value) -> bool:
	return typeof(value) == TYPE_INT

static func _is_int_min(value, minimum: int) -> bool:
	return _is_int(value) and int(value) >= minimum

## Matches the schema's `^[a-z0-9_-]+$` id pattern (entities, jobs, queue
## entries, inventory keys).
static func _matches_id_pattern(value) -> bool:
	if not (value is String):
		return false
	var text: String = value
	if text.is_empty():
		return false
	for i in range(text.length()):
		var c := text.unicode_at(i)
		var allowed := (c >= 97 and c <= 122) or (c >= 48 and c <= 57) or c == 45 or c == 95
		if not allowed:
			return false
	return true

## Matches the schema's `^[a-z0-9_-]*$` job.itemId pattern: like
## _matches_id_pattern but an empty string is valid (a non-haul job's
## harmless default, see JobQueue.submit_dig()).
static func _matches_optional_id_pattern(value) -> bool:
	if not (value is String):
		return false
	var text: String = value
	if text.is_empty():
		return true
	return _matches_id_pattern(text)

## issue #299 round 1: every persisted tile coordinate is bounds-checked
## against the map's own declared width/height, not just non-negative -- a
## job target/cell, route/search tile, or scheduling entry naming a
## coordinate outside the live map can never be smuggled in through a
## hand-edited or corrupted save (docs/architecture/save-system.md).
static func _valid_tile(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid tile type")
	var tile: Dictionary = value
	var check := _require_fields(tile, ["x", "y"], "tile")
	if not check["ok"]:
		return check
	if (not _is_int_min(tile["x"], 0) or not _is_int_min(tile["y"], 0)
			or int(tile["x"]) >= map_width or int(tile["y"]) >= map_height):
		return _fail("invalid tile coordinates")
	return {"ok": true}

static func _valid_tile_array(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Array):
		return _fail("invalid tile array type")
	for tile in value:
		var check := _valid_tile(tile, map_width, map_height)
		if not check["ok"]:
			return check
	return {"ok": true}

## "autonomous" (ADR 015 Amendment, issue #294) is optional on the wire, like
## "heldTool" on an entity: an older v19 save taken before this field existed
## never had one and defaults to false on decode (StateCodec._decode_entry()),
## so no migration step is needed for a same-schema-version addition.
static func _valid_queue_entry(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid queue entry type")
	var entry: Dictionary = value
	var required := ["id", "target", "base", "submittedTick", "ordinal", "restrictTo"]
	# _require_fields() would apply its own keys_allowed(dict, required) using
	# `required` alone, rejecting the optional "autonomous" field -- so its
	# two checks are inlined separately here instead of calling it directly.
	if not _keys_allowed(entry, required + ["autonomous"]):
		return _fail("unexpected queue entry field")
	for key in required:
		if not entry.has(key):
			return _fail_missing("missing queue entry field '%s'" % key)
	if not _matches_id_pattern(entry["id"]):
		return _fail("invalid queue entry id")
	var target_check := _valid_tile(entry["target"], map_width, map_height)
	if not target_check["ok"]:
		return target_check
	if not _is_int(entry["base"]) or not _is_int_min(entry["submittedTick"], 0) or not _is_int_min(entry["ordinal"], 0):
		return _fail("invalid queue entry fields")
	if not (entry["restrictTo"] is String) or not _matches_optional_id_pattern(entry["restrictTo"]):
		return _fail("invalid queue entry restrictTo")
	if entry.has("autonomous") and not (entry["autonomous"] is bool):
		return _fail("invalid queue entry autonomous")
	return {"ok": true}

static func _valid_route_state(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid route state type")
	var route: Dictionary = value
	var required := ["start", "target", "status", "frontier", "visited", "cameFrom", "path", "expansions", "resumeCalls"]
	var check := _require_fields(route, required, "route state")
	if not check["ok"]:
		return check
	var start_check := _valid_tile(route["start"], map_width, map_height)
	if not start_check["ok"]:
		return start_check
	var target_check := _valid_tile(route["target"], map_width, map_height)
	if not target_check["ok"]:
		return target_check
	if not (route["status"] is String) or not ["searching", "found", "unreachable"].has(route["status"]):
		return _fail("invalid route status")
	var frontier_check := _valid_tile_array(route["frontier"], map_width, map_height)
	if not frontier_check["ok"]:
		return frontier_check
	var visited_check := _valid_tile_array(route["visited"], map_width, map_height)
	if not visited_check["ok"]:
		return visited_check
	var path_check := _valid_tile_array(route["path"], map_width, map_height)
	if not path_check["ok"]:
		return path_check
	if not (route["cameFrom"] is Array):
		return _fail("invalid route cameFrom type")
	for pair in route["cameFrom"]:
		if not (pair is Dictionary):
			return _fail("invalid route cameFrom entry type")
		var pair_check := _require_fields(pair, ["child", "parent"], "cameFrom entry")
		if not pair_check["ok"]:
			return pair_check
		var child_check := _valid_tile(pair["child"], map_width, map_height)
		if not child_check["ok"]:
			return child_check
		var parent_check := _valid_tile(pair["parent"], map_width, map_height)
		if not parent_check["ok"]:
			return parent_check
	if not _is_int_min(route["expansions"], 0) or not _is_int_min(route["resumeCalls"], 0):
		return _fail("invalid route expansions or resumeCalls")
	return {"ok": true}

static func _valid_found_entry(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid found entry type")
	var found: Dictionary = value
	var required := ["worker", "entry", "travel"]
	var check := _require_fields(found, required, "found entry")
	if not check["ok"]:
		return check
	if not (found["worker"] is String):
		return _fail("invalid found entry worker")
	var entry_check := _valid_queue_entry(found["entry"], map_width, map_height)
	if not entry_check["ok"]:
		return entry_check
	if not _is_int_min(found["travel"], 0):
		return _fail("invalid found entry travel")
	return {"ok": true}

static func _valid_pending_entry(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid pending entry type")
	var pending: Dictionary = value
	var required := ["candidates", "cursor", "found", "start", "route"]
	var check := _require_fields(pending, required, "pending entry")
	if not check["ok"]:
		return check
	if not (pending["candidates"] is Array):
		return _fail("invalid pending candidates type")
	for candidate in pending["candidates"]:
		var candidate_check := _valid_queue_entry(candidate, map_width, map_height)
		if not candidate_check["ok"]:
			return candidate_check
	if not _is_int_min(pending["cursor"], 0):
		return _fail("invalid pending cursor")
	if not (pending["found"] is Array):
		return _fail("invalid pending found type")
	for found in pending["found"]:
		var found_check := _valid_found_entry(found, map_width, map_height)
		if not found_check["ok"]:
			return found_check
	var start_check := _valid_tile(pending["start"], map_width, map_height)
	if not start_check["ok"]:
		return start_check
	var route = pending["route"]
	if route == null:
		return {"ok": true}
	return _valid_route_state(route, map_width, map_height)

static func _valid_assignment_entry(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid assignment entry type")
	var assignment: Dictionary = value
	var required := ["jobId", "startedTick", "travelTicks", "path"]
	var check := _require_fields(assignment, required, "assignment entry")
	if not check["ok"]:
		return check
	if not (assignment["jobId"] is String) or not _is_int_min(assignment["startedTick"], 0) or not _is_int_min(assignment["travelTicks"], 0):
		return _fail("invalid assignment fields")
	var path_check := _valid_tile_array(assignment["path"], map_width, map_height)
	if not path_check["ok"]:
		return path_check
	return {"ok": true}

static func _valid_items(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid items type")
	var items: Dictionary = value
	var check := _require_fields(items, ["nextId", "list"], "items")
	if not check["ok"]:
		return check
	if not _is_int_min(items["nextId"], 1):
		return _fail("invalid items.nextId")
	if not (items["list"] is Array):
		return _fail("invalid items.list type")
	var seen_ids := {}
	for item in items["list"]:
		var item_check := _valid_item(item, map_width, map_height)
		if not item_check["ok"]:
			return item_check
		var item_id: String = (item as Dictionary)["id"]
		if seen_ids.has(item_id):
			return _fail("duplicate item id '%s'" % item_id)
		seen_ids[item_id] = true
	return {"ok": true}

## issue #299: map_width/map_height bound every position field below, on top
## of the pre-existing non-negative check -- an entity/item/object/zone at or
## beyond the map's own declared width/height is rejected the same way a
## negative one always was.
static func _valid_item(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid item type")
	var item: Dictionary = value
	var check := _require_fields(item, ["id", "x", "y", "kind", "count", "factionId"], "item")
	if not check["ok"]:
		return check
	if not _is_int_min(item["x"], 0) or not _is_int_min(item["y"], 0) or int(item["x"]) >= map_width or int(item["y"]) >= map_height:
		return _fail("invalid item position")
	if not _matches_id_pattern(item["id"]):
		return _fail("invalid item id")
	if not _matches_id_pattern(item["kind"]):
		return _fail("invalid item kind")
	if not _is_int_min(item["count"], 1):
		return _fail("invalid item count")
	if not _matches_id_pattern(item["factionId"]):
		return _fail("invalid item factionId")
	return {"ok": true}

## Mirrors _valid_items()/_valid_item(): world._tool_items' wire shape is
## {nextId, list} like the ground-item store, but each entry is
## {id, kind, location} (identity-bearing, colonist-ai.md 2/3.4) rather than
## {id, x, y, kind, count} (stackable).
static func _valid_tool_items(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid toolItems type")
	var tool_items: Dictionary = value
	var check := _require_fields(tool_items, ["nextId", "list"], "toolItems")
	if not check["ok"]:
		return check
	if not _is_int_min(tool_items["nextId"], 1):
		return _fail("invalid toolItems.nextId")
	if not (tool_items["list"] is Array):
		return _fail("invalid toolItems.list type")
	var seen_ids := {}
	for item in tool_items["list"]:
		var item_check := _valid_tool_item(item, map_width, map_height)
		if not item_check["ok"]:
			return item_check
		var item_id: String = (item as Dictionary)["id"]
		if seen_ids.has(item_id):
			return _fail("duplicate toolItems id '%s'" % item_id)
		seen_ids[item_id] = true
	return {"ok": true}

static func _valid_tool_item(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid toolItems entry type")
	var item: Dictionary = value
	var check := _require_fields(item, ["id", "kind", "location"], "toolItems entry")
	if not check["ok"]:
		return check
	if not _matches_id_pattern(item["id"]):
		return _fail("invalid toolItems entry id")
	if not _matches_id_pattern(item["kind"]):
		return _fail("invalid toolItems entry kind")
	return _valid_tool_location(item["location"], map_width, map_height)

## A tool item's location (StateCodec._encode_tool_location()) is a ground or
## stockpile tile, or a held-by-colonist reference -- never both a tile and a
## colonist id.
static func _valid_tool_location(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid tool location type")
	var location: Dictionary = value
	if not (location.get("type") is String):
		return _fail("invalid tool location type field")
	match String(location["type"]):
		"ground", "stockpile":
			var check := _require_fields(location, ["type", "x", "y"], "tool location")
			if not check["ok"]:
				return check
			if (not _is_int_min(location["x"], 0) or not _is_int_min(location["y"], 0)
					or int(location["x"]) >= map_width or int(location["y"]) >= map_height):
				return _fail("invalid tool location position")
			return {"ok": true}
		"held":
			var check := _require_fields(location, ["type", "colonistId"], "tool location")
			if not check["ok"]:
				return check
			if not _matches_id_pattern(location["colonistId"]):
				return _fail("invalid tool location colonistId")
			return {"ok": true}
		_:
			return _fail("invalid tool location type value")

## world._tool_reservations' wire shape is a plain item id -> job id map
## (ReservationTable.snapshot(), colonist-ai.md 3.4), mirroring "inventory"'s
## additionalProperties/propertyNames style rather than an array of entries.
## Every key must reference a currently-declared tool item: a reservation
## can never outlive the item it targets, let alone the job that holds it.
static func _valid_tool_reservations(value, tool_items_value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid toolReservations type")
	var reservations: Dictionary = value
	var known_ids := {}
	if tool_items_value is Dictionary and (tool_items_value as Dictionary).get("list") is Array:
		for item in ((tool_items_value as Dictionary)["list"] as Array):
			if item is Dictionary and item.get("id") is String:
				known_ids[String(item["id"])] = true
	for item_id in reservations.keys():
		if not _matches_id_pattern(item_id):
			return _fail("invalid toolReservations key")
		if not known_ids.has(String(item_id)):
			return _fail("toolReservations references unknown item '%s'" % item_id)
		if not (reservations[item_id] is String) or not _matches_id_pattern(reservations[item_id]):
			return _fail("invalid toolReservations value")
	return {"ok": true}

static func _valid_zones(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Array):
		return _fail("invalid zones type")
	var seen_ids := {}
	for zone in (value as Array):
		var zone_check := _valid_zone(zone, map_width, map_height)
		if not zone_check["ok"]:
			return zone_check
		var zone_id: String = (zone as Dictionary)["id"]
		if seen_ids.has(zone_id):
			return _fail("duplicate zone id '%s'" % zone_id)
		seen_ids[zone_id] = true
	return {"ok": true}

static func _valid_zone(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid zone type")
	var zone: Dictionary = value
	var check := _require_fields(zone, ["id", "x", "y", "width", "height"], "zone")
	if not check["ok"]:
		return check
	if not _matches_id_pattern(zone["id"]):
		return _fail("invalid zone id")
	if not _is_int_min(zone["x"], 0) or not _is_int_min(zone["y"], 0):
		return _fail("invalid zone position")
	if not _is_int_min(zone["width"], 1) or not _is_int_min(zone["height"], 1):
		return _fail("invalid zone dimensions")
	if int(zone["x"]) + int(zone["width"]) > map_width or int(zone["y"]) + int(zone["height"]) > map_height:
		return _fail("invalid zone bounds")
	return {"ok": true}

## Mirrors _valid_zones()/_valid_zone(): world._ground_berries's wire shape is
## an array of {target, berries} entries (see StateCodec._encode_ground_berries()),
## each a simple per-tile counter, not a first-class item with an id.
static func _valid_ground_berries(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Array):
		return _fail("invalid groundBerries type")
	for entry in (value as Array):
		var entry_check := _valid_ground_berries_entry(entry, map_width, map_height)
		if not entry_check["ok"]:
			return entry_check
	return {"ok": true}

static func _valid_ground_berries_entry(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid groundBerries entry type")
	var entry: Dictionary = value
	var check := _require_fields(entry, ["target", "berries"], "groundBerries entry")
	if not check["ok"]:
		return check
	var target_check := _valid_tile(entry["target"], map_width, map_height)
	if not target_check["ok"]:
		return target_check
	if not _is_int_min(entry["berries"], 1):
		return _fail("invalid groundBerries entry berries")
	return {"ok": true}

## Mirrors _valid_ground_berries()/_valid_ground_berries_entry():
## world._work_progress's wire shape is an array of {target, ticksRemaining}
## entries (see StateCodec._encode_work_progress()), colonist-ai.md 3.6's
## tile-keyed remaining-ticks store for an interruptible `work` toil.
static func _valid_work_progress(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Array):
		return _fail("invalid workProgress type")
	for entry in (value as Array):
		var entry_check := _valid_work_progress_entry(entry, map_width, map_height)
		if not entry_check["ok"]:
			return entry_check
	return {"ok": true}

## "ownerJobId" (round-2 review round-4 finding 4) is optional on the wire,
## like "autonomous" on a queue entry: present only when the tile's
## reservation was owned by a job when the entry was encoded, absent for the
## plain tile-keyed case every older save already used, so no migration step
## is needed for this same-schema-version addition.
static func _valid_work_progress_entry(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid workProgress entry type")
	var entry: Dictionary = value
	var required := ["target", "ticksRemaining"]
	if not _keys_allowed(entry, required + ["ownerJobId"]):
		return _fail("unexpected workProgress entry field")
	for key in required:
		if not entry.has(key):
			return _fail_missing("missing workProgress entry field '%s'" % key)
	var target_check := _valid_tile(entry["target"], map_width, map_height)
	if not target_check["ok"]:
		return target_check
	if not _is_int_min(entry["ticksRemaining"], 1):
		return _fail("invalid workProgress entry ticksRemaining")
	if entry.has("ownerJobId") and not _matches_id_pattern(entry["ownerJobId"]):
		return _fail("invalid workProgress entry ownerJobId")
	return {"ok": true}

## world._work_progress_owner's wire shape is an array of {target, jobId}
## entries (StateCodec._encode_work_progress_owners()), round-5 review
## (#278/#303): the exact job that owns a workProgress key, so decode() never
## has to guess it from whichever job happens to target that key. At most one
## job owns a given tile's progress, so duplicate targets are rejected the
## same way duplicate colonistId/actorId are for pausedJobs/combatBlockedTargets.
static func _valid_work_progress_owners(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Array):
		return _fail("invalid workProgressOwners type")
	var seen_targets := {}
	for entry in (value as Array):
		var entry_check := _valid_work_progress_owner_entry(entry, map_width, map_height)
		if not entry_check["ok"]:
			return entry_check
		var target: Dictionary = (entry as Dictionary)["target"]
		var target_key := "%s_%s" % [target["x"], target["y"]]
		if seen_targets.has(target_key):
			return _fail("duplicate workProgressOwners target")
		seen_targets[target_key] = true
	return {"ok": true}

static func _valid_work_progress_owner_entry(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid workProgressOwners entry type")
	var entry: Dictionary = value
	var check := _require_fields(entry, ["target", "jobId"], "workProgressOwners entry")
	if not check["ok"]:
		return check
	var target_check := _valid_tile(entry["target"], map_width, map_height)
	if not target_check["ok"]:
		return target_check
	if not _matches_id_pattern(entry["jobId"]):
		return _fail("invalid workProgressOwners entry jobId")
	return {"ok": true}

## world._suspended_work_progress's wire shape is an array of {jobId,
## ticksRemaining} entries (StateCodec._encode_suspended_work_progress()),
## round-6 review (#278/#303): a suspended job's own work-toil ticks, keyed
## by job_id alone (no tile coordinate -- unlike workProgress/
## workProgressOwners, at most one entry per job_id, never per tile, since a
## suspended job's snapshot has already left the shared tile cache). Optional
## on the wire like workProgressOwners.
static func _valid_suspended_work_progress(value) -> Dictionary:
	if not (value is Array):
		return _fail("invalid suspendedWorkProgress type")
	var seen_job_ids := {}
	for entry in (value as Array):
		var entry_check := _valid_suspended_work_progress_entry(entry)
		if not entry_check["ok"]:
			return entry_check
		var job_id: String = (entry as Dictionary)["jobId"]
		if seen_job_ids.has(job_id):
			return _fail("duplicate suspendedWorkProgress jobId '%s'" % job_id)
		seen_job_ids[job_id] = true
	return {"ok": true}

static func _valid_suspended_work_progress_entry(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid suspendedWorkProgress entry type")
	var entry: Dictionary = value
	var check := _require_fields(entry, ["jobId", "ticksRemaining"], "suspendedWorkProgress entry")
	if not check["ok"]:
		return check
	if not _matches_id_pattern(entry["jobId"]):
		return _fail("invalid suspendedWorkProgress entry jobId")
	if not _is_int_min(entry["ticksRemaining"], 1):
		return _fail("invalid suspendedWorkProgress entry ticksRemaining")
	return {"ok": true}

## world._paused_jobs's wire shape is an array of {colonistId, jobId} entries
## (see StateCodec._encode_paused_jobs()): the job a critical need interrupted
## mid-`work` (colonist-ai.md 3.6), to resume once the need job releases the
## colonist -- never a job record itself, so no reason/remedy/status here.
static func _valid_paused_jobs(value) -> Dictionary:
	if not (value is Array):
		return _fail("invalid pausedJobs type")
	var seen_colonists := {}
	for entry in (value as Array):
		var entry_check := _valid_paused_job_entry(entry)
		if not entry_check["ok"]:
			return entry_check
		var colonist_id: String = (entry as Dictionary)["colonistId"]
		if seen_colonists.has(colonist_id):
			return _fail("duplicate pausedJobs colonistId '%s'" % colonist_id)
		seen_colonists[colonist_id] = true
	return {"ok": true}

static func _valid_paused_job_entry(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid pausedJobs entry type")
	var entry: Dictionary = value
	var check := _require_fields(entry, ["colonistId", "jobId"], "pausedJobs entry")
	if not check["ok"]:
		return check
	if not _matches_id_pattern(entry["colonistId"]):
		return _fail("invalid pausedJobs entry colonistId")
	if not _matches_id_pattern(entry["jobId"]):
		return _fail("invalid pausedJobs entry jobId")
	return {"ok": true}

## world._need_giver's own colonist_id -> job_id association's wire shape is
## an array of {colonistId, jobId} entries -- the same shape as pausedJobs
## (see StateCodec._encode_paused_jobs(), reused for both), naming the need
## job a critical-need onset submitted for that colonist (colonist-ai.md
## 3.1/3.6) rather than the job it interrupted.
static func _valid_need_job_assignments(value) -> Dictionary:
	if not (value is Array):
		return _fail("invalid needJobAssignments type")
	var seen_colonists := {}
	for entry in (value as Array):
		var entry_check := _valid_need_job_assignment_entry(entry)
		if not entry_check["ok"]:
			return entry_check
		var colonist_id: String = (entry as Dictionary)["colonistId"]
		if seen_colonists.has(colonist_id):
			return _fail("duplicate needJobAssignments colonistId '%s'" % colonist_id)
		seen_colonists[colonist_id] = true
	return {"ok": true}

static func _valid_need_job_assignment_entry(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid needJobAssignments entry type")
	var entry: Dictionary = value
	var check := _require_fields(entry, ["colonistId", "jobId"], "needJobAssignments entry")
	if not check["ok"]:
		return check
	if not _matches_id_pattern(entry["colonistId"]):
		return _fail("invalid needJobAssignments entry colonistId")
	if not _matches_id_pattern(entry["jobId"]):
		return _fail("invalid needJobAssignments entry jobId")
	return {"ok": true}

## RescueGiver's own job_id -> victim_id association's wire shape (issue #360
## round-3 review finding 1) is an array of {jobId, victimId} entries -- keyed
## by job id, not colonist id, since a rescue job's own id is what's actually
## unique here (see StateCodec._encode_rescue_victim_assignments()). Optional
## at the top level (SaveIO._validate_state()): absent for any save written
## before rescue existed.
static func _valid_rescue_victim_assignments(value) -> Dictionary:
	if not (value is Array):
		return _fail("invalid rescueVictimAssignments type")
	var seen_jobs := {}
	for entry in (value as Array):
		var entry_check := _valid_rescue_victim_assignment_entry(entry)
		if not entry_check["ok"]:
			return entry_check
		var job_id: String = (entry as Dictionary)["jobId"]
		if seen_jobs.has(job_id):
			return _fail("duplicate rescueVictimAssignments jobId '%s'" % job_id)
		seen_jobs[job_id] = true
	return {"ok": true}

static func _valid_rescue_victim_assignment_entry(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid rescueVictimAssignments entry type")
	var entry: Dictionary = value
	var check := _require_fields(entry, ["jobId", "victimId"], "rescueVictimAssignments entry")
	if not check["ok"]:
		return check
	if not _matches_id_pattern(entry["jobId"]):
		return _fail("invalid rescueVictimAssignments entry jobId")
	if not _matches_id_pattern(entry["victimId"]):
		return _fail("invalid rescueVictimAssignments entry victimId")
	return {"ok": true}

## CombatGiver's own per-actor flee-destination exclusion set (round-6
## review): the wire shape is an array of {actorId, tiles} entries, each
## `tiles` an array of #/$defs/tile -- see
## StateCodec._encode_combat_blocked_targets().
static func _valid_combat_blocked_targets(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Array):
		return _fail("invalid combatBlockedTargets type")
	var seen_actors := {}
	for entry in (value as Array):
		var entry_check := _valid_combat_blocked_targets_entry(entry, map_width, map_height)
		if not entry_check["ok"]:
			return entry_check
		var actor_id: String = (entry as Dictionary)["actorId"]
		if seen_actors.has(actor_id):
			return _fail("duplicate combatBlockedTargets actorId '%s'" % actor_id)
		seen_actors[actor_id] = true
	return {"ok": true}

static func _valid_combat_blocked_targets_entry(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid combatBlockedTargets entry type")
	var entry: Dictionary = value
	var check := _require_fields(entry, ["actorId", "tiles"], "combatBlockedTargets entry")
	if not check["ok"]:
		return check
	if not _matches_id_pattern(entry["actorId"]):
		return _fail("invalid combatBlockedTargets entry actorId")
	var tiles_check := _valid_tile_array(entry["tiles"], map_width, map_height)
	if not tiles_check["ok"]:
		return tiles_check
	return {"ok": true}

## ApproachGiver's own job_id -> target association (issue #390, ADR 031): the
## wire shape is an array of {jobId, kind, actorId} or {jobId, kind, tile}
## entries -- see StateCodec._encode_approach_job_targets().
static func _valid_approach_job_targets(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Array):
		return _fail("invalid approachJobTargets type")
	var seen_jobs := {}
	for entry in (value as Array):
		var entry_check := _valid_approach_job_target_entry(entry, map_width, map_height)
		if not entry_check["ok"]:
			return entry_check
		var job_id: String = (entry as Dictionary)["jobId"]
		if seen_jobs.has(job_id):
			return _fail("duplicate approachJobTargets jobId '%s'" % job_id)
		seen_jobs[job_id] = true
	return {"ok": true}

static func _valid_approach_job_target_entry(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid approachJobTargets entry type")
	var entry: Dictionary = value
	if not (entry.get("kind") is String) or not ["actor", "object"].has(entry["kind"]):
		return _fail("invalid approachJobTargets entry kind")
	var is_actor := String(entry["kind"]) == "actor"
	var check := _require_fields(entry, ["jobId", "kind", "actorId"] if is_actor else ["jobId", "kind", "tile"], "approachJobTargets entry")
	if not check["ok"]:
		return check
	if not _matches_id_pattern(entry["jobId"]):
		return _fail("invalid approachJobTargets entry jobId")
	if is_actor:
		if not _matches_id_pattern(entry["actorId"]):
			return _fail("invalid approachJobTargets entry actorId")
		return {"ok": true}
	return _valid_tile(entry["tile"], map_width, map_height)

## Legacy structural check for a save written before issue #391 (ApproachGiver
## no longer retires an actor permanently): the wire shape is a plain array of
## actor_id strings. state_codec.gd's decode() no longer reads this field, but
## an old save that still carries it must not be rejected outright.
static func _valid_approach_retired_actors(value) -> Dictionary:
	if not (value is Array):
		return _fail("invalid approachRetiredActors type")
	var seen_actors := {}
	for entry in (value as Array):
		if not (entry is String) or not _matches_id_pattern(entry):
			return _fail("invalid approachRetiredActors entry")
		var actor_id: String = entry
		if seen_actors.has(actor_id):
			return _fail("duplicate approachRetiredActors actorId '%s'" % actor_id)
		seen_actors[actor_id] = true
	return {"ok": true}

## world._calendar_alerts_fired's wire shape is {fired: [windowId, ...]}
## (StateCodec._encode_calendar_alerts()), a flat set of calendar window ids
## that have already fired their one-shot alert (ADR 008 consequence 6).
## Window ids come from content/calendar.json, whose own schema
## (game/content/schemas/calendar.schema.json) allows any non-empty string
## -- not the stricter ^[a-z0-9_-]+$ entity/job/item id pattern -- so a valid
## calendar id like "SpringSow" must still validate here.
static func _valid_calendar_alerts(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid calendarAlerts type")
	var calendar_alerts: Dictionary = value
	var check := _require_fields(calendar_alerts, ["fired"], "calendarAlerts")
	if not check["ok"]:
		return check
	if not (calendar_alerts["fired"] is Array):
		return _fail("invalid calendarAlerts.fired type")
	var seen_ids := {}
	for window_id in (calendar_alerts["fired"] as Array):
		if not (window_id is String) or (window_id as String).is_empty():
			return _fail("invalid calendarAlerts.fired entry")
		if seen_ids.has(window_id):
			return _fail("duplicate calendarAlerts.fired id '%s'" % window_id)
		seen_ids[window_id] = true
	return {"ok": true}

## _tool_fetch's per-job excluded-candidate set (issue #271 round 6/ADR 012,
## schemaVersion 17) is an array of {jobId, toolIds} entries (StateCodec.
## _encode_tool_fetch_excluded()), one per job with at least one candidate
## already proven unreachable this fetch attempt. Every toolId must reference
## a currently-declared tool item, mirroring toolReservations' own cross-check
## -- an excluded candidate can never outlive the item it names.
static func _valid_tool_fetch_excluded(value, tool_items_value) -> Dictionary:
	if not (value is Array):
		return _fail("invalid toolFetchExcluded type")
	var known_ids := {}
	if tool_items_value is Dictionary and (tool_items_value as Dictionary).get("list") is Array:
		for item in ((tool_items_value as Dictionary)["list"] as Array):
			if item is Dictionary and item.get("id") is String:
				known_ids[String(item["id"])] = true
	var seen_jobs := {}
	for entry in (value as Array):
		if not (entry is Dictionary):
			return _fail("invalid toolFetchExcluded entry type")
		var check := _require_fields(entry, ["jobId", "toolIds"], "toolFetchExcluded entry")
		if not check["ok"]:
			return check
		if not _matches_id_pattern(entry["jobId"]):
			return _fail("invalid toolFetchExcluded entry jobId")
		if seen_jobs.has(entry["jobId"]):
			return _fail("duplicate toolFetchExcluded jobId '%s'" % entry["jobId"])
		seen_jobs[entry["jobId"]] = true
		if not (entry["toolIds"] is Array) or (entry["toolIds"] as Array).is_empty():
			return _fail("invalid toolFetchExcluded entry toolIds")
		for tool_id in (entry["toolIds"] as Array):
			if not (tool_id is String) or not _matches_id_pattern(tool_id):
				return _fail("invalid toolFetchExcluded entry toolId")
			if not known_ids.has(String(tool_id)):
				return _fail("toolFetchExcluded references unknown item '%s'" % tool_id)
	return {"ok": true}

## world._incidents' own continuation state (StateCodec._encode_incident_scheduler(),
## ADR 004 "WorldState's diagnostic hash includes this continuation state"):
## a per-incident-id day when its cooldown next clears, the day the scheduler
## last ran its daily draw, and its own independent RNG stream. Every
## cooldownUntilDay key must reference a currently-declared incidents.json id
## pattern -- like every other id-keyed map in this file -- though (unlike
## toolReservations/toolFetchExcluded) it is never cross-checked against
## content/incidents.json itself: that would require SaveIO to load content,
## which no other check here does either.
static func _valid_incident_scheduler(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid incidentScheduler type")
	var incident_scheduler: Dictionary = value
	var check := _require_fields(incident_scheduler, ["cooldownUntilDay", "lastProcessedDay", "rng"], "incidentScheduler")
	if not check["ok"]:
		return check
	if not (incident_scheduler["cooldownUntilDay"] is Dictionary):
		return _fail("invalid incidentScheduler.cooldownUntilDay type")
	var cooldown_until_day: Dictionary = incident_scheduler["cooldownUntilDay"]
	for incident_id in cooldown_until_day.keys():
		if not _matches_id_pattern(incident_id):
			return _fail("invalid incidentScheduler.cooldownUntilDay key")
		if not _is_int_min(cooldown_until_day[incident_id], 0):
			return _fail("invalid incidentScheduler.cooldownUntilDay value")
	if not _is_int_min(incident_scheduler["lastProcessedDay"], 0):
		return _fail("invalid incidentScheduler.lastProcessedDay")
	if not (incident_scheduler["rng"] is Dictionary):
		return _fail("invalid incidentScheduler.rng type")
	var rng_check := _require_fields(incident_scheduler["rng"], ["seed", "state"], "incidentScheduler.rng")
	if not rng_check["ok"]:
		return rng_check
	if not _is_int(incident_scheduler["rng"]["seed"]) or not _is_int(incident_scheduler["rng"]["state"]):
		return _fail("invalid incidentScheduler.rng fields")
	return {"ok": true}

## world._dig_find_random's own continuation (ADR 025 round 2 review,
## StateCodec._encode()'s "digFindRng"): the same {seed, state} shape as
## top-level "rng", but only checked when the caller already confirmed the
## key is present -- see _validate_state()'s own comment on why this field is
## optional rather than joining top_level's required-fields loop.
static func _valid_dig_find_rng(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid digFindRng type")
	var rng: Dictionary = value
	if not _keys_allowed(rng, ["seed", "state"]):
		return _fail("unexpected digFindRng field")
	if not rng.has("seed") or not rng.has("state"):
		return _fail_missing("missing digFindRng field")
	if not _is_int(rng["seed"]) or not _is_int(rng["state"]):
		return _fail("invalid digFindRng fields")
	return {"ok": true}

## The optional "health" key is present only for an object whose kind
## declares "max_health" (F5/#302), mirroring how "rerouting" is optional on
## an entity's route (_valid_entity_route() below) -- allowed via the
## required+optional union passed to _keys_allowed(), not through
## _require_fields() (whose single "required" array doubles as the exhaustive
## allowed set, which would reject "health" outright as unexpected). The
## optional "orientation" key (issue #405) is this same union's other member:
## "horizontal", "vertical", "" or absent, with "" and absent both meaning
## "no rotation" (review round 1: the schema and codec must accept an
## explicit "" identically to the key's absence, since either represents the
## default orientation for every footprint-[1,1] kind and every save written
## before this task).
static func _valid_object(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid objects entry type")
	var object_entry: Dictionary = value
	var required := ["target", "kind", "factionId"]
	var optional := ["health", "orientation"]
	if not _keys_allowed(object_entry, required + optional):
		return _fail("unexpected objects entry field")
	for key in required:
		if not object_entry.has(key):
			return _fail_missing("missing objects entry field '%s'" % key)
	var target_check := _valid_tile(object_entry["target"], map_width, map_height)
	if not target_check["ok"]:
		return target_check
	if not _matches_id_pattern(object_entry["kind"]):
		return _fail("invalid objects entry kind")
	if not _matches_id_pattern(object_entry["factionId"]):
		return _fail("invalid objects entry factionId")
	if object_entry.has("orientation") and not (object_entry["orientation"] == "" or object_entry["orientation"] == "horizontal" or object_entry["orientation"] == "vertical"):
		return _fail("invalid objects entry orientation")
	if not object_entry.has("health"):
		return {"ok": true}
	return _valid_object_health(object_entry["health"])

## F5/#302: mirrors the schema's "object.health" $def. Optional at the
## objects-entry level -- the key's absence is allowed (checked by the caller
## above) for a bare/non-damageable object and for any save written before
## this task, exactly like route.rerouting (_valid_entity_route() above);
## present only for an object whose kind declares "max_health"
## (content/objects.json), same as world._object_health. Once the key IS
## present, though, its value must be a valid Dictionary: an explicit
## `"health": null` is rejected here (round-5 review), not waved through as
## "absent" -- the schema's object $def has no null variant, and
## StateCodec._decode_objects() assigns item["health"] straight into a typed
## Dictionary variable the instant item.has("health") is true, which errors
## on null rather than failing gracefully.
static func _valid_object_health(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid objects entry health type")
	var health: Dictionary = value
	var check := _require_fields(health, ["hp", "maxHp"], "objects entry health")
	if not check["ok"]:
		return check
	if not _is_int_min(health["hp"], 0):
		return _fail("invalid objects entry health hp")
	if not _is_int_min(health["maxHp"], 1):
		return _fail("invalid objects entry health maxHp")
	return {"ok": true}

## issue #406: mirrors the schema's "constructionSite" $def -- one record per
## active construction site, structurally independent of any job.
static func _valid_construction_site(value, map_width: int, map_height: int) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid constructionSites entry type")
	var site: Dictionary = value
	var required := ["id", "kind", "origin", "orientation", "requiredMaterials", "heldMaterials", "progress", "buildTicks", "maxBuilders", "builderIds"]
	if not _keys_allowed(site, required):
		return _fail("unexpected constructionSites entry field")
	for key in required:
		if not site.has(key):
			return _fail_missing("missing constructionSites entry field '%s'" % key)
	if not _matches_id_pattern(site["id"]):
		return _fail("invalid constructionSites entry id")
	if not _matches_id_pattern(site["kind"]):
		return _fail("invalid constructionSites entry kind")
	var origin_check := _valid_tile(site["origin"], map_width, map_height)
	if not origin_check["ok"]:
		return origin_check
	if not (site["orientation"] == "" or site["orientation"] == "horizontal" or site["orientation"] == "vertical"):
		return _fail("invalid constructionSites entry orientation")
	if not (site["requiredMaterials"] is Array):
		return _fail("invalid constructionSites entry requiredMaterials type")
	for entry in site["requiredMaterials"]:
		var material_check := _valid_material_entry(entry)
		if not material_check["ok"]:
			return material_check
	if not (site["heldMaterials"] is Array):
		return _fail("invalid constructionSites entry heldMaterials type")
	for entry in site["heldMaterials"]:
		var held_check := _valid_material_entry(entry)
		if not held_check["ok"]:
			return held_check
	if not _is_int_min(site["progress"], 0):
		return _fail("invalid constructionSites entry progress")
	if not _is_int_min(site["buildTicks"], 1):
		return _fail("invalid constructionSites entry buildTicks")
	if not _is_int_min(site["maxBuilders"], 1):
		return _fail("invalid constructionSites entry maxBuilders")
	if not (site["builderIds"] is Array):
		return _fail("invalid constructionSites entry builderIds type")
	for id in site["builderIds"]:
		if not _matches_id_pattern(id):
			return _fail("invalid constructionSites entry builderIds")
	return {"ok": true}

static func _valid_material_entry(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid constructionSites entry material type")
	var check := _require_fields(value, ["item", "quantity"], "constructionSites entry material")
	if not check["ok"]:
		return check
	if not _matches_id_pattern(value["item"]):
		return _fail("invalid constructionSites entry material item")
	if not _is_int_min(value["quantity"], 0):
		return _fail("invalid constructionSites entry material quantity")
	return {"ok": true}

## The optional "rerouting" key is present only while a re-route search is
## in flight (see StateCodec._encode_route_field()); its absence keeps a
## schemaVersion-4-shaped save (4 keys) accepted unchanged, matching the
## migration's default-to-non-rerouting rule in save_migrations.gd.
static func _valid_entity_route(value, map_width: int, map_height: int) -> Dictionary:
	if value == null:
		return {"ok": true}
	if not (value is Dictionary):
		return _fail("invalid entity route type")
	var route: Dictionary = value
	var required := ["jobId", "path", "step", "moveTicksRemaining"]
	var optional := ["rerouting"]
	if not _keys_allowed(route, required + optional):
		return _fail("unexpected entity route field")
	for key in required:
		if not route.has(key):
			return _fail_missing("missing entity route field '%s'" % key)
	if not (route["jobId"] is String):
		return _fail("invalid entity route jobId")
	var path_check := _valid_tile_array(route["path"], map_width, map_height)
	if not path_check["ok"]:
		return path_check
	if (route["path"] as Array).size() < 1:
		return _fail("entity route path must have at least one tile")
	if not _is_int_min(route["step"], 0) or not _is_int_min(route["moveTicksRemaining"], 0):
		return _fail("invalid entity route step or moveTicksRemaining")
	if route.has("rerouting") and route["rerouting"] != null:
		var rerouting_check := _valid_route_state(route["rerouting"], map_width, map_height)
		if not rerouting_check["ok"]:
			return rerouting_check
	return {"ok": true}

## Mirrors the inline entity-needs check above: labourTable (colonist-ai.md
## 3.2) is a fixed 7-kind Dictionary, each level an int 0..4.
static func _valid_labour_table(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid entity labourTable type")
	var labour_kinds := ["mine", "chop", "farm", "haul", "build", "craft", "cook"]
	var check := _require_fields(value, labour_kinds, "entity labourTable")
	if not check["ok"]:
		return check
	for kind in labour_kinds:
		if not _is_int(value[kind]) or int(value[kind]) < 0 or int(value[kind]) > 4:
			return _fail("invalid entity labourTable level '%s'" % kind)
	return {"ok": true}

## Mirrors the schema's "trapped" $def (issue #359): unlike carrying/work
## (present only for kinds whose own component shape adds them), any actor
## kind may fall into a trench, so this is validated unconditionally, like
## route/health, never gated by entity.has().
static func _valid_entity_trapped(value, map_width: int, map_height: int) -> Dictionary:
	if value == null:
		return {"ok": true}
	if not (value is Dictionary):
		return _fail("invalid entity trapped type")
	var trapped: Dictionary = value
	if not _keys_allowed(trapped, ["tile", "ticksRemaining", "fromTile"]) or not trapped.has("tile"):
		return _fail_missing("invalid entity trapped fields")
	var tile_check := _valid_tile(trapped["tile"], map_width, map_height)
	if not tile_check["ok"]:
		return tile_check
	if trapped.has("ticksRemaining") and not _is_int_min(trapped["ticksRemaining"], 1):
		return _fail("invalid entity trapped ticksRemaining")
	if trapped.has("fromTile"):
		var from_tile_check := _valid_tile(trapped["fromTile"], map_width, map_height)
		if not from_tile_check["ok"]:
			return from_tile_check
	return {"ok": true}

static func _valid_entity_work(value) -> Dictionary:
	if value == null:
		return {"ok": true}
	if not (value is Dictionary):
		return _fail("invalid entity work type")
	var work: Dictionary = value
	var check := _require_fields(work, ["jobId", "ticksRemaining"], "entity work")
	if not check["ok"]:
		return check
	if not (work["jobId"] is String) or not _is_int_min(work["ticksRemaining"], 0):
		return _fail("invalid entity work fields")
	return {"ok": true}

## Mirrors the schema's "health" $def: the F2 health component snapshot
## (StateCodec._encode_health()/_decode_health()), always present -- unlike
## route/work/carrying it is never null.
static func _valid_entity_health(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid entity health type")
	var health: Dictionary = value
	var check := _require_fields(health, ["hp", "maxHp", "dead"], "entity health")
	if not check["ok"]:
		return check
	if not _is_int_min(health["hp"], 0):
		return _fail("invalid entity health hp")
	if not _is_int_min(health["maxHp"], 1):
		return _fail("invalid entity health maxHp")
	if not (health["dead"] is bool):
		return _fail("invalid entity health dead")
	return {"ok": true}

## Mirrors the schema's "combat" $def (ActorCombat.build(), F2/issue #294).
static func _valid_entity_combat(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid entity combat type")
	var check := _require_fields(value, ["attack", "damage", "cooldown", "cooldownRemaining"], "entity combat")
	if not check["ok"]:
		return check
	if (not _is_int_min(value["attack"], 0) or not _is_int_min(value["damage"], 0)
			or not _is_int_min(value["cooldown"], 1) or not _is_int_min(value["cooldownRemaining"], 0)):
		return _fail("invalid entity combat fields")
	return {"ok": true}

## Mirrors the schema's "inventoryComponent" $def (ActorInventory.build(),
## F2/issue #294): items array, tool slot id (or ""), capacity >= 1.
static func _valid_entity_inventory(value) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid entity inventory type")
	var check := _require_fields(value, ["items", "tool", "capacity"], "entity inventory")
	if not check["ok"]:
		return check
	if not (value["items"] is Array) or not (value["tool"] is String) or not _matches_optional_id_pattern(value["tool"]):
		return _fail("invalid entity inventory fields")
	if not _is_int_min(value["capacity"], 1):
		return _fail("invalid entity inventory capacity")
	return {"ok": true}

## Issue #402: a colonist's "hands" list, at most one entry per distinct kind
## (no item id, no ground position -- see StateCodec._encode_hands_field()),
## every entry's count >= 1, and the sum of every entry's count never
## exceeding ActorInventory.HANDS_CAPACITY.
static func _valid_entity_hands(value) -> Dictionary:
	if not (value is Array):
		return _fail("invalid entity hands type")
	var hands: Array = value
	var seen_kinds := {}
	var total := 0
	for raw_entry in hands:
		if not (raw_entry is Dictionary):
			return _fail("invalid entity hands entry type")
		var entry: Dictionary = raw_entry
		var check := _require_fields(entry, ["kind", "count"], "entity hands entry")
		if not check["ok"]:
			return check
		if not _matches_id_pattern(entry["kind"]):
			return _fail("invalid entity hands entry kind")
		if not _is_int_min(entry["count"], 1):
			return _fail("invalid entity hands entry count")
		if seen_kinds.has(entry["kind"]):
			return _fail("duplicate entity hands entry kind")
		seen_kinds[entry["kind"]] = true
		total += int(entry["count"])
	if total > InventoryType.HANDS_CAPACITY:
		return _fail("entity hands total count exceeds capacity")
	return {"ok": true}

static func _sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()

static func _remove_temporary(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

static func _replace_target(temporary: String, target: String) -> Dictionary:
	# DirAccess.rename overwrites an existing destination directly on every
	# platform Godot supports, so this single rename call is both the
	# replacement step and the only moment the target's directory entry
	# changes. There is no intermediate step where target refers to neither
	# the old nor the new save.
	var temporary_absolute := ProjectSettings.globalize_path(temporary)
	var target_absolute := ProjectSettings.globalize_path(target)
	var rename_error := DirAccess.rename_absolute(temporary_absolute, target_absolute)
	if rename_error != OK:
		return {"ok": false, "code": "rename_failed", "message": "could not atomically replace save (%s)" % rename_error}
	return {"ok": true}

static func _error(code: String, message: String, file: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message, "file": file}
