class_name ContentRegistry
extends RefCounted

## F1 content registry (docs/architecture/foundation-for-breadth.md section F1):
## at construction, reads every required game/content/*.json file, validates
## it against its schema under game/content/schemas/, cross-checks
## references between files, and freezes the loaded bundle. Scene-independent
## (AGENTS.md): plain FileAccess + JSON parsing only, no scene/node/rendering/
## wall-clock/global-randomness dependency, so it is constructible from a
## headless test exactly like WorldState itself.
##
## Never applies a silent default: a missing file, a schema violation or a
## dangling cross-file reference leaves the registry invalid (is_valid() ==
## false) with a typed, structured error (get_error(): {code, message, file})
## instead of a partially-populated bundle. This class never crashes the
## process on a bad bundle -- that lets a test construct one against a
## deliberately broken fixture and assert on the resulting error. A caller
## that requires valid content before it may proceed (WorldState._init()) is
## responsible for treating an invalid registry as fatal itself.

const DEFAULT_CONTENT_DIR := "res://content/"
const DEFAULT_SCHEMA_DIR := "res://content/schemas/"

## Collection kinds are id-indexed arrays (jobs/needs/objects each keyed by
## their "kind" field, items keyed by its "id" field -- content shapes are not
## uniform, so the id field is looked up per kind); calendar/manifest are
## singleton documents with no per-id entries, so they are validated and
## frozen but not exposed through get()/list().
const COLLECTION_KINDS: Array[String] = ["jobs", "needs", "objects", "items", "tiles", "actors", "factions", "incidents"]
const DOCUMENT_KINDS: Array[String] = ["calendar", "manifest", "mapgen"]
const ID_FIELD_BY_KIND := {"jobs": "kind", "needs": "kind", "objects": "kind", "items": "id", "tiles": "id", "actors": "id", "factions": "id", "incidents": "id"}

## Compile-time mirror of content/tiles.json ids and content/mapgen.json's
## colonist_count field: the only literal source for values ~20 tests and the
## out-of-scope viewer read as WorldState.<NAME> class constants, something
## GDScript's const-folding cannot source from a runtime-loaded JSON file.
## world_state.gd's own TILE_*/COLONIST_COUNT consts alias these rather than
## redeclaring the literals. There is no compile-time SPAWN_AREA_* mirror
## (issue #300): the colonist spawn clearing is chosen dynamically per world
## by WorldGenerator.place_spawn(), not a single fixed rectangle -- see
## WorldState.get_spawn_clearing() and docs/decisions/020.
const TILE_ROCK := "rock"
const TILE_SOIL := "soil"
const TILE_FLOOR := "floor"
const TILE_PLOWED_SOIL := "plowed_soil"
const TILE_PLANTED := "planted"
const TILE_HAZARD := "hazard"
const TILE_TREE := "tree"
const TILE_WATER := "water"
const TILE_TRENCH := "trench"
const COLONIST_COUNT := 3

const ERROR_MISSING_FILE := "missing_file"
const ERROR_INVALID_JSON := "invalid_json"
const ERROR_SCHEMA_VIOLATION := "schema_violation"
const ERROR_DANGLING_REFERENCE := "dangling_reference"

## Only used for its static, dependency-free is_known_toil() vocabulary check
## (jobs.json declaring a toil ToilExecutor does not implement is exactly the
## kind of dangling reference this registry exists to catch); this registry
## never constructs or drives a ToilExecutor instance.
const ToilExecutorType = preload("res://scripts/core/jobs/toil_executor.gd")

## Only used for its static, dependency-free is_known_component() vocabulary
## check (actors.json declaring a component ActorTable does not implement is
## exactly the kind of dangling reference this registry exists to catch,
## mirroring is_known_toil() above); this registry never spawns an actor.
const ActorTableType = preload("res://scripts/core/actors/actor_table.gd")

## Only used for its static, dependency-free RELATION_VALUES/
## is_known_relation_value() vocabulary check (factions.json declaring a
## relation value outside "hostile"/"neutral"/"friendly" is exactly the kind
## of dangling reference this registry exists to catch, mirroring
## is_known_toil()/is_known_component() above); this registry never
## constructs a Relations instance. Relations itself takes its registry
## parameter untyped rather than preloading this file, so there is no
## preload cycle.
const RelationsType = preload("res://scripts/core/relations/relations.gd")

## {} when valid; otherwise {"code": String, "message": String, "file": String}.
var _error: Dictionary = {}
## kind -> Dictionary[id -> frozen entry Dictionary], for COLLECTION_KINDS only.
var _collections: Dictionary = {}
## kind -> frozen whole-document Dictionary, for DOCUMENT_KINDS only.
var _documents: Dictionary = {}

func _init(content_dir: String = DEFAULT_CONTENT_DIR, schema_dir: String = DEFAULT_SCHEMA_DIR) -> void:
	var required_kinds := COLLECTION_KINDS + DOCUMENT_KINDS
	var discovered_kinds := _discover_content_kinds(content_dir)
	for kind in required_kinds:
		if not discovered_kinds.has(kind):
			_fail(ERROR_MISSING_FILE, "missing content file for kind '%s'" % kind, _join_path(content_dir, "%s.json" % kind))
			return

	## Every discovered game/content/*.json file is loaded and validated when
	## it has a matching game/content/schemas/*.schema.json file (the task's
	## "every ... file that has a matching schema" clause) -- not just the
	## fixed COLLECTION_KINDS/DOCUMENT_KINDS list, so a future content kind
	## added with its schema is never silently skipped. A required kind
	## missing its schema is still a fatal ERROR_MISSING_FILE, exactly as
	## before; a non-required file with no matching schema is simply not this
	## registry's concern and is left unread.
	var raw_by_kind: Dictionary = {}
	var extra_kinds: Array[String] = []
	for kind in discovered_kinds:
		var is_required := required_kinds.has(kind)
		var content_path := _join_path(content_dir, "%s.json" % kind)
		var schema_path := _join_path(schema_dir, "%s.schema.json" % kind)
		if not FileAccess.file_exists(schema_path):
			if is_required:
				_fail(ERROR_MISSING_FILE, "missing schema file for kind '%s'" % kind, schema_path)
				return
			continue
		var content_result := _read_json(content_path)
		if not content_result["ok"]:
			_fail(ERROR_INVALID_JSON, content_result["message"], content_path)
			return
		var schema_result := _read_json(schema_path)
		if not schema_result["ok"]:
			_fail(ERROR_INVALID_JSON, schema_result["message"], schema_path)
			return
		var validation := _validate_node(content_result["value"], schema_result["value"], kind)
		if not validation["ok"]:
			_fail(ERROR_SCHEMA_VIOLATION, validation["message"], content_path)
			return
		raw_by_kind[kind] = content_result["value"]
		if not is_required:
			extra_kinds.append(kind)

	var cross_check := _check_references(raw_by_kind)
	if not cross_check["ok"]:
		_fail(ERROR_DANGLING_REFERENCE, cross_check["message"], cross_check["file"])
		return

	var job_yields_check := _check_job_yields(raw_by_kind)
	if not job_yields_check["ok"]:
		_fail(ERROR_SCHEMA_VIOLATION, job_yields_check["message"], job_yields_check["file"])
		return

	var actor_tunables_check := _check_actor_component_tunables(raw_by_kind)
	if not actor_tunables_check["ok"]:
		_fail(ERROR_SCHEMA_VIOLATION, actor_tunables_check["message"], actor_tunables_check["file"])
		return

	for kind in COLLECTION_KINDS:
		_collections[kind] = _freeze_collection(raw_by_kind[kind], kind)
	for kind in DOCUMENT_KINDS:
		_documents[kind] = _freeze_document(raw_by_kind[kind])
	for kind in extra_kinds:
		_documents[kind] = _freeze_document(raw_by_kind[kind])

func is_valid() -> bool:
	return _error.is_empty()

func get_error() -> Dictionary:
	return _error.duplicate(true)

## The frozen entry named id within kind's collection, or a frozen empty
## Dictionary when kind is not a collection kind or names no such id (a
## caller must never be able to mutate a "not found" result any more than a
## found one). Named get_entry() rather than get(): Object already declares
## get(property: StringName) -> Variant, and GDScript refuses to override it
## with a different signature ("The function signature doesn't match the
## parent", verified against this exact method).
func get_entry(kind: String, id: String) -> Dictionary:
	var collection: Dictionary = _collections.get(kind, {})
	if collection.has(id):
		return collection[id]
	return _frozen_empty_dict()

## Every frozen entry in kind's collection, id-sorted for determinism; the
## returned Array is itself read-only, on top of each frozen entry inside it.
## A frozen empty Array when kind is not a collection kind, for the same
## reason get_entry() freezes its "not found" result.
func list(kind: String) -> Array:
	if not _collections.has(kind):
		return _frozen_empty_array()
	var collection: Dictionary = _collections[kind]
	var ids := collection.keys()
	ids.sort()
	var entries: Array = []
	for id in ids:
		entries.append(collection[id])
	entries.make_read_only()
	return entries

## manifest.json's "version" field, or "" when the registry is invalid.
func version() -> String:
	var manifest: Dictionary = _documents.get("manifest", {})
	return String(manifest.get("version", ""))

## The frozen whole-document Dictionary for a DOCUMENT_KINDS kind (e.g.
## "mapgen": rock-vein/hazard/tree/water counts and placement attempts, the
## spawn area and colonist count -- singleton content with no per-id
## collection shape), or a frozen empty Dictionary when kind is unknown, for
## the same reason get_entry()/list() freeze their "not found" result.
func document(kind: String) -> Dictionary:
	if _documents.has(kind):
		return _documents[kind]
	return _frozen_empty_dict()

func _frozen_empty_dict() -> Dictionary:
	var empty: Dictionary = {}
	empty.make_read_only()
	return empty

func _frozen_empty_array() -> Array:
	var empty: Array = []
	empty.make_read_only()
	return empty

func _fail(code: String, message: String, file: String) -> void:
	_error = {"code": code, "message": message, "file": file}
	push_error("ContentRegistry: [%s] %s (%s)" % [code, message, file])

func _join_path(dir: String, file_name: String) -> String:
	if dir.ends_with("/"):
		return dir + file_name
	return dir + "/" + file_name

## Every *.json file found directly inside content_dir (not recursing into
## schema_dir or any other subdirectory), as kind names (file name minus the
## ".json" suffix), sorted for deterministic iteration order. An empty array
## when content_dir cannot be opened at all -- required-kind membership
## checking in _init() turns that into a typed ERROR_MISSING_FILE per kind
## rather than a distinct "directory missing" error.
func _discover_content_kinds(content_dir: String) -> Array[String]:
	var kinds: Array[String] = []
	var dir := DirAccess.open(content_dir)
	if dir == null:
		return kinds
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".json"):
			kinds.append(file_name.substr(0, file_name.length() - ".json".length()))
		file_name = dir.get_next()
	dir.list_dir_end()
	kinds.sort()
	return kinds

func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "message": "could not open %s" % path}
	var text := file.get_as_text()
	file.close()
	var parsed := _parse_json(text)
	if not parsed["ok"]:
		return {"ok": false, "message": "%s: %s" % [path, parsed["message"]]}
	var value = parsed["value"]
	if typeof(value) != TYPE_DICTIONARY and typeof(value) != TYPE_ARRAY:
		return {"ok": false, "message": "%s did not parse as a JSON object or array" % path}
	return {"ok": true, "value": value}

## Godot's built-in JSON.parse_string() always returns JSON numbers as
## TYPE_FLOAT -- verified directly: JSON.parse_string('{"a":1}')'s "a" has
## typeof() == TYPE_FLOAT, never TYPE_INT, regardless of whether the source
## literal was "1" or "1.0". That is correct per the JSON spec (which has one
## "number" type, not separate int/float), but it means the int/float
## distinction JSON Schema's "integer" type depends on is destroyed before
## _validate_node ever runs. This hand-rolled recursive-descent parser
## replaces JSON.parse_string for content/schema files so that distinction
## survives: a number literal with no '.' and no exponent parses as a
## GDScript int, everything else as a float.
func _parse_json(text: String) -> Dictionary:
	var cursor := _JsonCursor.new(text)
	var value = _json_parse_value(cursor)
	if cursor.failed():
		return {"ok": false, "message": cursor.error_message}
	cursor.skip_whitespace()
	if not cursor.at_end():
		return {"ok": false, "message": "trailing content after JSON value (at offset %d)" % cursor.pos}
	return {"ok": true, "value": value}

class _JsonCursor extends RefCounted:
	var text: String
	var length: int
	var pos: int = 0
	var error_message: String = ""

	func _init(source: String) -> void:
		text = source
		length = source.length()

	func failed() -> bool:
		return not error_message.is_empty()

	func fail(message: String) -> void:
		if error_message.is_empty():
			error_message = "%s (at offset %d)" % [message, pos]

	func at_end() -> bool:
		return pos >= length

	func peek() -> String:
		if at_end():
			return ""
		return text[pos]

	func skip_whitespace() -> void:
		while not at_end():
			var c := text[pos]
			if c == " " or c == "\t" or c == "\n" or c == "\r":
				pos += 1
			else:
				break

func _json_parse_value(c: _JsonCursor):
	c.skip_whitespace()
	if c.at_end():
		c.fail("unexpected end of input")
		return null
	var ch := c.peek()
	if ch == "{":
		return _json_parse_object(c)
	if ch == "[":
		return _json_parse_array(c)
	if ch == "\"":
		return _json_parse_string(c)
	if ch == "t" or ch == "f":
		return _json_parse_bool(c)
	if ch == "n":
		return _json_parse_null(c)
	if ch == "-" or (ch >= "0" and ch <= "9"):
		return _json_parse_number(c)
	c.fail("unexpected character '%s'" % ch)
	return null

func _json_parse_object(c: _JsonCursor) -> Dictionary:
	var result := {}
	c.pos += 1 # consume '{'
	c.skip_whitespace()
	if c.peek() == "}":
		c.pos += 1
		return result
	while true:
		c.skip_whitespace()
		if c.peek() != "\"":
			c.fail("expected string key")
			return result
		var key := _json_parse_string(c)
		if c.failed():
			return result
		c.skip_whitespace()
		if c.peek() != ":":
			c.fail("expected ':' after object key")
			return result
		c.pos += 1
		var value = _json_parse_value(c)
		if c.failed():
			return result
		result[key] = value
		c.skip_whitespace()
		var next := c.peek()
		if next == ",":
			c.pos += 1
			continue
		if next == "}":
			c.pos += 1
			break
		c.fail("expected ',' or '}' in object")
		break
	return result

func _json_parse_array(c: _JsonCursor) -> Array:
	var result := []
	c.pos += 1 # consume '['
	c.skip_whitespace()
	if c.peek() == "]":
		c.pos += 1
		return result
	while true:
		var value = _json_parse_value(c)
		if c.failed():
			return result
		result.append(value)
		c.skip_whitespace()
		var next := c.peek()
		if next == ",":
			c.pos += 1
			continue
		if next == "]":
			c.pos += 1
			break
		c.fail("expected ',' or ']' in array")
		break
	return result

func _json_parse_string(c: _JsonCursor) -> String:
	c.pos += 1 # consume opening quote
	var out := ""
	while true:
		if c.at_end():
			c.fail("unterminated string")
			return out
		var ch := c.text[c.pos]
		if ch == "\"":
			c.pos += 1
			return out
		if ch == "\\":
			c.pos += 1
			if c.at_end():
				c.fail("unterminated escape sequence")
				return out
			var esc := c.text[c.pos]
			match esc:
				"\"": out += "\""
				"\\": out += "\\"
				"/": out += "/"
				"b": out += "\b"
				"f": out += "\f"
				"n": out += "\n"
				"r": out += "\r"
				"t": out += "\t"
				"u":
					if c.pos + 4 >= c.length:
						c.fail("truncated unicode escape")
						return out
					var hex := c.text.substr(c.pos + 1, 4)
					if not _is_hex4(hex):
						c.fail("invalid unicode escape '\\u%s'" % hex)
						return out
					out += char(hex.hex_to_int())
					c.pos += 4
				_:
					c.fail("invalid escape character '%s'" % esc)
					return out
			c.pos += 1
			continue
		# JSON forbids a raw (unescaped) control character inside a string
		# literal (RFC 8259 SS7); only an escape may produce one.
		if ch.unicode_at(0) < 0x20:
			c.fail("unescaped control character (code %d) in string" % ch.unicode_at(0))
			return out
		out += ch
		c.pos += 1
	return out

func _is_hex4(s: String) -> bool:
	if s.length() != 4:
		return false
	for i in 4:
		if not _is_hex_digit(s[i]):
			return false
	return true

func _is_hex_digit(ch: String) -> bool:
	return (ch >= "0" and ch <= "9") or (ch >= "a" and ch <= "f") or (ch >= "A" and ch <= "F")

func _is_digit(ch: String) -> bool:
	return ch >= "0" and ch <= "9"

## Full RFC 8259 SS6 number grammar, not a lenient superset of it: a leading
## zero followed by another digit (e.g. "01"), a decimal point with no digit
## after it (e.g. "1."), and an exponent marker with no digit after it (e.g.
## "1e") are each rejected rather than silently truncated, since a truncated
## read here would leave the cursor mid-token and desync every error message
## and offset that follows.
func _json_parse_number(c: _JsonCursor):
	var start := c.pos
	var is_float := false
	if c.peek() == "-":
		c.pos += 1
	if c.at_end() or not _is_digit(c.text[c.pos]):
		c.fail("invalid number literal")
		return 0
	if c.text[c.pos] == "0":
		c.pos += 1
	else:
		while not c.at_end() and _is_digit(c.text[c.pos]):
			c.pos += 1
	if not c.at_end() and c.text[c.pos] == ".":
		is_float = true
		c.pos += 1
		if c.at_end() or not _is_digit(c.text[c.pos]):
			c.fail("invalid number literal: expected a digit after '.'")
			return 0
		while not c.at_end() and _is_digit(c.text[c.pos]):
			c.pos += 1
	if not c.at_end() and (c.text[c.pos] == "e" or c.text[c.pos] == "E"):
		is_float = true
		c.pos += 1
		if not c.at_end() and (c.text[c.pos] == "+" or c.text[c.pos] == "-"):
			c.pos += 1
		if c.at_end() or not _is_digit(c.text[c.pos]):
			c.fail("invalid number literal: expected a digit after exponent marker")
			return 0
		while not c.at_end() and _is_digit(c.text[c.pos]):
			c.pos += 1
	var token := c.text.substr(start, c.pos - start)
	if is_float:
		return float(token)
	return int(token)

func _json_parse_bool(c: _JsonCursor) -> bool:
	if c.text.substr(c.pos, 4) == "true":
		c.pos += 4
		return true
	if c.text.substr(c.pos, 5) == "false":
		c.pos += 5
		return false
	c.fail("invalid literal")
	return false

func _json_parse_null(c: _JsonCursor):
	if c.text.substr(c.pos, 4) == "null":
		c.pos += 4
		return null
	c.fail("invalid literal")
	return null

## Minimal JSON Schema subset sufficient for game/content/schemas/*: type,
## required, properties, additionalProperties, items, minItems, minLength,
## minimum. Not a general-purpose validator -- no $ref, oneOf, pattern, etc.
## additionalProperties is only ever enforced as a plain boolean false (an
## "unexpected field" rejection); a schema-valued additionalProperties (the
## standard JSON Schema way to constrain a dynamic-keyed object's values,
## used by factions.schema.json's "relations") is accepted but not applied --
## inert in this minimal validator the same way "enum" already is (see
## docs/decisions/012-actors-and-components.md), never a crash: the
## string-type and enum constraint it would have expressed for
## factions.json's "relations" values is instead enforced explicitly in
## _check_references(), which is reached for every relations value
## regardless of this validator's schema-valued additionalProperties support.
func _validate_node(value, schema: Dictionary, path: String) -> Dictionary:
	var type_field = schema.get("type", "")
	if typeof(type_field) == TYPE_ARRAY:
		return _validate_node_against_type_options(value, schema, type_field as Array, path)
	var type_name := String(type_field)
	match type_name:
		"object":
			if typeof(value) != TYPE_DICTIONARY:
				return {"ok": false, "message": "%s: expected an object" % path}
			var dict: Dictionary = value
			for required_field in (schema.get("required", []) as Array):
				if not dict.has(required_field):
					return {"ok": false, "message": "%s: missing required field '%s'" % [path, required_field]}
			var properties: Dictionary = schema.get("properties", {})
			var additional_properties = schema.get("additionalProperties", true)
			if typeof(additional_properties) == TYPE_BOOL and additional_properties == false:
				for key in dict.keys():
					if not properties.has(key):
						return {"ok": false, "message": "%s: unexpected field '%s'" % [path, key]}
			for key in properties.keys():
				if dict.has(key):
					var sub := _validate_node(dict[key], properties[key], "%s.%s" % [path, key])
					if not sub["ok"]:
						return sub
		"array":
			if typeof(value) != TYPE_ARRAY:
				return {"ok": false, "message": "%s: expected an array" % path}
			var arr: Array = value
			if schema.has("minItems") and arr.size() < int(schema["minItems"]):
				return {"ok": false, "message": "%s: expected at least %d item(s)" % [path, schema["minItems"]]}
			if schema.has("items"):
				for i in arr.size():
					var sub := _validate_node(arr[i], schema["items"], "%s[%d]" % [path, i])
					if not sub["ok"]:
						return sub
		"string":
			if typeof(value) != TYPE_STRING:
				return {"ok": false, "message": "%s: expected a string" % path}
			if schema.has("minLength") and String(value).length() < int(schema["minLength"]):
				return {"ok": false, "message": "%s: string shorter than minLength %d" % [path, schema["minLength"]]}
		"integer":
			if typeof(value) != TYPE_INT:
				return {"ok": false, "message": "%s: expected an integer" % path}
			if schema.has("minimum") and float(value) < float(schema["minimum"]):
				return {"ok": false, "message": "%s: value below minimum %s" % [path, schema["minimum"]]}
		"number":
			if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
				return {"ok": false, "message": "%s: expected a number" % path}
			if schema.has("minimum") and float(value) < float(schema["minimum"]):
				return {"ok": false, "message": "%s: value below minimum %s" % [path, schema["minimum"]]}
			if schema.has("exclusiveMinimum") and float(value) <= float(schema["exclusiveMinimum"]):
				return {"ok": false, "message": "%s: value must be above %s" % [path, schema["exclusiveMinimum"]]}
		"boolean":
			if typeof(value) != TYPE_BOOL:
				return {"ok": false, "message": "%s: expected a boolean" % path}
		"null":
			if typeof(value) != TYPE_NIL:
				return {"ok": false, "message": "%s: expected null" % path}
	return {"ok": true}

## A schema's "type" may be an array of type names (e.g. ["string", "null"]),
## standard JSON Schema for "this field is one of several primitive shapes" --
## used by jobs.schema.json's yields.find_table[].item, which is either an
## item id string or null (issue #357 review round 1: a bare "item": {} schema
## silently accepted any JSON value, so a wrong-typed item was only caught
## later, by _check_references(), which misreported it as a dangling
## reference instead of a structural violation). value passes when it matches
## at least one option; sibling constraints (minLength, minimum, ...) are
## re-checked per option against a duplicated schema, so they only apply to
## the option they belong to -- minLength never rejects a null value just
## because the string option also lists it.
func _validate_node_against_type_options(value, schema: Dictionary, type_options: Array, path: String) -> Dictionary:
	for option in type_options:
		var option_schema := schema.duplicate()
		option_schema["type"] = option
		var result := _validate_node(value, option_schema, path)
		if result["ok"]:
			return result
	return {"ok": false, "message": "%s: value does not match any of type %s" % [path, type_options]}

## Cross-file reference checks (docs/architecture/foundation-for-breadth.md F1
## "a test... fails on any dangling reference"): a job's needs_tool must name
## a declared item of kind "tool"; a job's toils must all be toils
## ToilExecutor implements; a need's source_kind must either be the reserved
## literal "tile" (a generated-terrain source, not content-declared -- see
## world_state.gd's TILE_* constants, out of this task's scope to move into
## content) or name a declared object kind; every faction's relations row
## (docs/decisions/015-factions-and-relations.md) must name only other
## declared faction ids, one row per other faction, no self-row, and each
## value must be a JSON string that is a known relation value -- checked in
## that order (own type before RelationsType.is_known_relation_value()) so a
## non-string JSON value (number, boolean, null, array, object) never reaches
## a GDScript String() conversion, which throws "Nonexistent 'String'
## constructor" for those types instead of returning gracefully (verified
## directly in this engine version); and an actor definition's optional faction_id (not
## yet declared by any real content/actors.json entry -- adding it there is
## a later task's scope, see the ADR) must name a declared faction id when
## present. Issue #278/round-3 (issue #403: build_cost became a list of
## {item, quantity}, one entry per required kind, not a single object): an
## object's optional build_cost entries name the wood/stone/etc a `build` job
## hauls from a stockpile before placing the object (see content/jobs.json's
## "build" entry) -- exactly the same shape of cross-file reference as a
## job's needs_tool above, checked the same way for every list position: an
## undeclared item id at any index fails construction typed
## dangling_reference naming objects.json, never loading as valid content
## that would otherwise only surface at play time as a runtime
## blocked_missing_input.
func _check_references(raw_by_kind: Dictionary) -> Dictionary:
	var item_kind_by_id: Dictionary = {}
	for entry in (raw_by_kind["items"]["items"] as Array):
		item_kind_by_id[String(entry["id"])] = String(entry.get("kind", ""))

	var known_object_kinds: Dictionary = {}
	for entry in (raw_by_kind["objects"]["objects"] as Array):
		known_object_kinds[String(entry["kind"])] = true
		if entry.has("build_cost"):
			for cost_entry in (entry["build_cost"] as Array):
				var cost_item_id := String((cost_entry as Dictionary).get("item", ""))
				if not item_kind_by_id.has(cost_item_id):
					return {"ok": false, "file": "objects.json",
						"message": "object '%s' build_cost.item '%s' names an unknown item id" % [String(entry["kind"]), cost_item_id]}

	for job in (raw_by_kind["jobs"]["jobs"] as Array):
		var job_kind := String(job.get("kind", "?"))
		if job.has("needs_tool"):
			var tool_id := String(job["needs_tool"])
			if not item_kind_by_id.has(tool_id):
				return {"ok": false, "file": "jobs.json",
					"message": "job '%s' needs_tool '%s' names an unknown item id" % [job_kind, tool_id]}
			if item_kind_by_id[tool_id] != "tool":
				return {"ok": false, "file": "jobs.json",
					"message": "job '%s' needs_tool '%s' names an item that is not kind 'tool'" % [job_kind, tool_id]}
		for toil in (job.get("toils", []) as Array):
			if not ToilExecutorType.is_known_toil(String(toil)):
				return {"ok": false, "file": "jobs.json",
					"message": "job '%s' declares unknown toil '%s'" % [job_kind, toil]}
		if job.has("yields"):
			var yields: Dictionary = job["yields"]
			for always_item in (yields.get("always", []) as Array):
				var always_id := String(always_item)
				if not item_kind_by_id.has(always_id):
					return {"ok": false, "file": "jobs.json",
						"message": "job '%s' yields.always names an unknown item id '%s'" % [job_kind, always_id]}
			for find_entry in (yields.get("find_table", []) as Array):
				var find_dict: Dictionary = find_entry
				var item_raw = find_dict.get("item")
				if typeof(item_raw) == TYPE_NIL:
					continue
				var find_id: String = item_raw
				if not item_kind_by_id.has(find_id):
					return {"ok": false, "file": "jobs.json",
						"message": "job '%s' yields.find_table names an unknown item id '%s'" % [job_kind, find_id]}

	for need in (raw_by_kind["needs"]["needs"] as Array):
		var need_kind := String(need.get("kind", "?"))
		var source_kind := String(need.get("source_kind", ""))
		if source_kind != "tile" and not known_object_kinds.has(source_kind):
			return {"ok": false, "file": "needs.json",
				"message": "need '%s' source_kind '%s' names an unknown object kind" % [need_kind, source_kind]}

	var known_faction_ids: Dictionary = {}
	for entry in (raw_by_kind["factions"]["factions"] as Array):
		known_faction_ids[String(entry["id"])] = true

	for faction in (raw_by_kind["factions"]["factions"] as Array):
		var faction_id := String(faction.get("id", "?"))
		var relations: Dictionary = faction.get("relations", {})
		for other_id in known_faction_ids.keys():
			if other_id == faction_id:
				continue
			if not relations.has(other_id):
				return {"ok": false, "file": "factions.json",
					"message": "faction '%s' relations is missing a row for '%s'" % [faction_id, other_id]}
		for other_id in relations.keys():
			var other_id_str := String(other_id)
			if other_id_str == faction_id:
				return {"ok": false, "file": "factions.json",
					"message": "faction '%s' relations names itself" % faction_id}
			if not known_faction_ids.has(other_id_str):
				return {"ok": false, "file": "factions.json",
					"message": "faction '%s' relations names an unknown faction id '%s'" % [faction_id, other_id_str]}
			var relation_raw = relations[other_id]
			if typeof(relation_raw) != TYPE_STRING:
				return {"ok": false, "file": "factions.json",
					"message": "faction '%s' relation to '%s' must be a string, got %s (%s)"
						% [faction_id, other_id_str, type_string(typeof(relation_raw)), relation_raw]}
			var relation_value: String = relation_raw
			if not RelationsType.is_known_relation_value(relation_value):
				return {"ok": false, "file": "factions.json",
					"message": "faction '%s' relation to '%s' has an unknown value '%s'" % [faction_id, other_id_str, relation_value]}

	var known_actor_ids: Dictionary = {}
	for actor in (raw_by_kind["actors"]["actors"] as Array):
		var actor_id := String(actor.get("id", "?"))
		known_actor_ids[actor_id] = true
		for component in (actor.get("components", []) as Array):
			if not ActorTableType.is_known_component(String(component)):
				return {"ok": false, "file": "actors.json",
					"message": "actor '%s' declares unknown component '%s'" % [actor_id, component]}
		if actor.has("faction_id"):
			var faction_id := String(actor["faction_id"])
			if not known_faction_ids.has(faction_id):
				return {"ok": false, "file": "actors.json",
					"message": "actor '%s' faction_id '%s' names an unknown faction id" % [actor_id, faction_id]}

	## F5 incidents (foundation-for-breadth.md F5, issue #294): an incident's
	## faction must name a declared faction id, and its spawn.actor_def must
	## name a declared actor id -- the same dangling_reference typed error as
	## every other cross-file check above, never a silent skip.
	for incident in (raw_by_kind["incidents"]["incidents"] as Array):
		var incident_id := String(incident.get("id", "?"))
		var incident_faction := String(incident.get("faction", ""))
		if not known_faction_ids.has(incident_faction):
			return {"ok": false, "file": "incidents.json",
				"message": "incident '%s' faction '%s' names an unknown faction id" % [incident_id, incident_faction]}
		var spawn: Dictionary = incident.get("spawn", {})
		var actor_def := String(spawn.get("actor_def", ""))
		if not known_actor_ids.has(actor_def):
			return {"ok": false, "file": "incidents.json",
				"message": "incident '%s' spawn.actor_def '%s' names an unknown actor id" % [incident_id, actor_def]}

	return {"ok": true}

## Structural validation of a job's optional yields.find_table (issue #357,
## docs/decisions/025-trench-trapped-actor-and-rescue.md): each entry's weight
## is already a non-negative integer per jobs.schema.json's "integer"/
## "minimum: 0", but the table's weights summing to exactly 100 is a
## cross-field arithmetic rule the minimal JSON Schema subset (_validate_node)
## cannot express, so it is checked here instead, after _check_references()
## has already confirmed every named item id resolves. A job with no
## "yields" field (every kind but "dig" today) is skipped entirely.
func _check_job_yields(raw_by_kind: Dictionary) -> Dictionary:
	for job in (raw_by_kind["jobs"]["jobs"] as Array):
		var job_kind := String(job.get("kind", "?"))
		if not job.has("yields"):
			continue
		var yields: Dictionary = job["yields"]
		var total := 0
		for find_entry in (yields.get("find_table", []) as Array):
			var find_dict: Dictionary = find_entry
			total += int(find_dict.get("weight", 0))
		if total != 100:
			return {"ok": false, "file": "jobs.json",
				"message": "job '%s' yields.find_table weights must sum to 100, got %d" % [job_kind, total]}
	return {"ok": true}

## Per-component tunable validation (docs/decisions/012-actors-and-components.md):
## for every actor definition, every declared component's own validate(tunables)
## must pass. Runs only after _check_references() has confirmed every declared
## component name is known, so a missing "actors" tunables key for a declared
## component (an empty Dictionary, per Dictionary.get()'s default) and a
## cross-field rule a single-field schema check cannot express (health.hp <=
## maxHp, worker.labour_min <= labour_default <= labour_max) are both caught
## here rather than silently defaulting during ActorTable.spawn().
func _check_actor_component_tunables(raw_by_kind: Dictionary) -> Dictionary:
	for actor in (raw_by_kind["actors"]["actors"] as Array):
		var actor_id := String(actor.get("id", "?"))
		var tunables: Dictionary = actor.get("tunables", {})
		for component in (actor.get("components", []) as Array):
			var component_name := String(component)
			var component_tunables: Dictionary = tunables.get(component_name, {})
			if not ActorTableType.validate_component(component_name, component_tunables):
				return {"ok": false, "file": "actors.json",
					"message": "actor '%s' component '%s' has invalid tunables %s"
						% [actor_id, component_name, component_tunables]}
	return {"ok": true}

func _freeze_collection(document: Dictionary, kind: String) -> Dictionary:
	var id_field: String = ID_FIELD_BY_KIND[kind]
	var entries: Array = document.get(kind, [])
	var frozen: Dictionary = {}
	for entry in entries:
		var entry_dict: Dictionary = entry
		frozen[String(entry_dict[id_field])] = _deep_freeze(entry_dict.duplicate(true))
	frozen.make_read_only()
	return frozen

## Freezes a whole parsed document (top-level Dictionary or Array, per
## _read_json's accepted shapes) for storage in _documents, used for both
## DOCUMENT_KINDS and any extra discovered kind that is not a COLLECTION_KIND.
func _freeze_document(value):
	if typeof(value) == TYPE_DICTIONARY:
		return _deep_freeze((value as Dictionary).duplicate(true))
	return _deep_freeze((value as Array).duplicate(true))

## Recursively freezes a fresh (duplicated) Dictionary/Array tree so no nested
## structure remains mutable, bottom-up: children are frozen before the
## parent that holds them is frozen, since a read-only Dictionary/Array
## refuses further key/index assignment.
func _deep_freeze(value):
	if typeof(value) == TYPE_DICTIONARY:
		var dict: Dictionary = value
		for key in dict.keys():
			dict[key] = _deep_freeze(dict[key])
		dict.make_read_only()
		return dict
	if typeof(value) == TYPE_ARRAY:
		var arr: Array = value
		for i in arr.size():
			arr[i] = _deep_freeze(arr[i])
		arr.make_read_only()
		return arr
	return value
