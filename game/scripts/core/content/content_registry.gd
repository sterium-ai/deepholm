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
## A16 (ADR 053): collection kinds a bundle may omit; otherwise handled like COLLECTION_KINDS.
const OPTIONAL_COLLECTION_KINDS: Array[String] = ["scenarios"]
const ID_FIELD_BY_KIND := {"jobs": "kind", "needs": "kind", "objects": "kind", "items": "id", "tiles": "id", "actors": "id", "factions": "id", "incidents": "id", "scenarios": "id"}
## The fields each scenario setup step (world/scenario_builder.gd) reads besides step/when.
const SCENARIO_STEP_FIELDS := {
	"needed_tools": [], "per_colonist_objects": ["kind"], "object_rows": ["seed_offset", "rows"],
	"dig_orders": ["count", "seed_offset", "priority"], "till_plot": ["search_radius", "tick_budget"],
	"ground_items": ["kind", "count", "search_radius"],
}

## Compile-time mirror of content/tiles.json ids and content/mapgen.json's
## colonist_count field: the only literal source for values many tests and
## the viewer read as WorldState.<NAME> class constants, something
## GDScript's const-folding cannot source from a runtime-loaded JSON file.
## world_state.gd's own TILE_*/COLONIST_COUNT consts alias these rather than
## redeclaring the literals. There is no compile-time SPAWN_AREA_* mirror:
## the colonist spawn clearing is chosen dynamically per world
## by WorldGenerator.place_spawn(), not a single fixed rectangle -- see
## WorldState.get_spawn_clearing() and ADR 020.
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

## Content packs (A13, ADR 010 amendment): a pack root is a directory holding
## PACK_MANIFEST_FILE plus collection-kind files; see _apply_pack_root().
const PACK_MANIFEST_FILE := "pack.json"
const PACK_SCHEMA_FILE := "pack.schema.json"
const PACK_OVERRIDES_FIELD := "overrides"

## Reads and parses content and schema files, keeping JSON's int/float split.
const ContentJsonType = preload("res://scripts/core/content/content_json.gd")

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
## Frozen [{id, version}] of the pack roots applied on top of the base, in order.
var _packs: Array = []

func _init(content_dir: String = DEFAULT_CONTENT_DIR, schema_dir: String = DEFAULT_SCHEMA_DIR,
		pack_dirs: Array[String] = []) -> void:
	var schemas_by_kind: Dictionary = {}
	var raw_by_kind := _load_base_root(content_dir, schema_dir, schemas_by_kind)
	if not is_valid():
		return
	## Packs apply in the order given, each on top of everything before it
	## (A13): a later pack may override an entry an earlier pack appended.
	var applied_packs: Array[Dictionary] = []
	for pack_dir in pack_dirs:
		var pack := _apply_pack_root(pack_dir, schema_dir, raw_by_kind, schemas_by_kind, applied_packs)
		if not is_valid():
			return
		applied_packs.append(pack)

	var cross_check := _check_references(raw_by_kind)
	if not cross_check["ok"]:
		_fail(ERROR_DANGLING_REFERENCE, cross_check["message"], cross_check["file"])
		return

	var job_effects_error: Array[String] = _check_job_effects(raw_by_kind)
	if not job_effects_error.is_empty():
		_fail(job_effects_error[0], job_effects_error[1], "jobs.json")
		return

	var actor_tunables_check := _check_actor_component_tunables(raw_by_kind)
	if not actor_tunables_check["ok"]:
		_fail(ERROR_SCHEMA_VIOLATION, actor_tunables_check["message"], actor_tunables_check["file"])
		return

	var scenario_check := _check_scenarios(raw_by_kind)
	if not scenario_check["ok"]:
		_fail("%s" % scenario_check["code"], "%s" % scenario_check["message"], "scenarios.json")
		return

	for kind: String in raw_by_kind.keys():
		var raw_document: Variant = raw_by_kind[kind]
		if _is_collection_kind(kind):
			_collections[kind] = _freeze_collection(raw_document as Dictionary, kind)
		else:
			_documents[kind] = _freeze_document(raw_document)
	_packs = Array(applied_packs)
	_deep_freeze(_packs)

## Loads the base root: every discovered content_dir/*.json file is loaded and
## validated when it has a matching schema_dir/*.schema.json file -- not just
## the fixed COLLECTION_KINDS/DOCUMENT_KINDS list, so a future content kind
## added with its schema is never silently skipped. A required kind missing
## its file or schema is a fatal ERROR_MISSING_FILE; a non-required file with
## no matching schema is simply not this registry's concern and is left
## unread. A collection kind naming one id twice is a schema_violation (it
## used to overwrite the earlier entry silently in _freeze_collection()).
## Each loaded schema is kept in schemas_by_kind for the pack roots.
func _load_base_root(content_dir: String, schema_dir: String, schemas_by_kind: Dictionary) -> Dictionary:
	var required_kinds := COLLECTION_KINDS + DOCUMENT_KINDS
	var discovered_kinds := _discover_content_kinds(content_dir)
	var raw_by_kind: Dictionary = {}
	for kind in required_kinds:
		if not discovered_kinds.has(kind):
			_fail(ERROR_MISSING_FILE, "missing content file for kind '%s'" % kind, _join_path(content_dir, "%s.json" % kind))
			return raw_by_kind

	for kind in discovered_kinds:
		var content_path := _join_path(content_dir, "%s.json" % kind)
		var schema_path := _join_path(schema_dir, "%s.schema.json" % kind)
		if not FileAccess.file_exists(schema_path):
			if required_kinds.has(kind):
				_fail(ERROR_MISSING_FILE, "missing schema file for kind '%s'" % kind, schema_path)
				return raw_by_kind
			continue
		var content_result := ContentJsonType.read_json(content_path)
		if not content_result["ok"]:
			_fail(ERROR_INVALID_JSON, content_result["message"], content_path)
			return raw_by_kind
		var schema_result := ContentJsonType.read_json(schema_path)
		if not schema_result["ok"]:
			_fail(ERROR_INVALID_JSON, schema_result["message"], schema_path)
			return raw_by_kind
		var validation := _validate_node(content_result["value"], schema_result["value"], kind)
		if not validation["ok"]:
			_fail(ERROR_SCHEMA_VIOLATION, validation["message"], content_path)
			return raw_by_kind
		if _is_collection_kind(kind):
			var collection_entries: Array = content_result["value"][kind]
			var duplicate := _first_duplicate_id(collection_entries, kind)
			if not duplicate.is_empty():
				_fail(ERROR_SCHEMA_VIOLATION, "%s: duplicate id '%s'" % [kind, duplicate], content_path)
				return raw_by_kind
		raw_by_kind[kind] = content_result["value"]
		schemas_by_kind[kind] = schema_result["value"]
	return raw_by_kind

## Applies one pack root (A13, ADR 010 amendment) to raw_by_kind and returns
## its {id, version}. A pack root holds PACK_MANIFEST_FILE ({id, version},
## validated by PACK_SCHEMA_FILE) and any subset of the collection kinds, each
## file shaped {"<kind>": [new entries], "overrides": [replacement entries]}
## with both lists optional. A pack file for a document kind or for a kind
## the base has no schema for is a schema_violation, never silently skipped.
func _apply_pack_root(pack_dir: String, schema_dir: String, raw_by_kind: Dictionary,
		schemas_by_kind: Dictionary, packs_so_far: Array[Dictionary]) -> Dictionary:
	var manifest_path := _join_path(pack_dir, PACK_MANIFEST_FILE)
	if not FileAccess.file_exists(manifest_path):
		_fail(ERROR_MISSING_FILE, "content pack has no %s" % PACK_MANIFEST_FILE, manifest_path)
		return {}
	var manifest_result := ContentJsonType.read_json(manifest_path)
	if not manifest_result["ok"]:
		_fail_with(ERROR_INVALID_JSON, manifest_result, manifest_path)
		return {}
	var pack_schema_path := _join_path(schema_dir, PACK_SCHEMA_FILE)
	var pack_schema_result := ContentJsonType.read_json(pack_schema_path)
	if not pack_schema_result["ok"]:
		_fail_with(ERROR_MISSING_FILE, pack_schema_result, pack_schema_path)
		return {}
	var pack_schema: Dictionary = pack_schema_result["value"]
	var manifest_value: Variant = manifest_result["value"]
	var manifest_check := _validate_node(manifest_value, pack_schema, "pack")
	if not manifest_check["ok"]:
		_fail_with(ERROR_SCHEMA_VIOLATION, manifest_check, manifest_path)
		return {}
	var manifest: Dictionary = manifest_value
	var pack_id: String = manifest["id"]
	var pack_version: String = manifest["version"]
	for earlier: Dictionary in packs_so_far:
		if earlier["id"] == pack_id:
			_fail(ERROR_SCHEMA_VIOLATION, "content pack id '%s' is listed twice" % pack_id, manifest_path)
			return {}

	for kind in _discover_content_kinds(pack_dir):
		if kind == PACK_MANIFEST_FILE.get_basename():
			continue
		var content_path := _join_path(pack_dir, "%s.json" % kind)
		if not _is_collection_kind(kind) or not schemas_by_kind.has(kind):
			_fail(ERROR_SCHEMA_VIOLATION, "a content pack may only add to or override a collection kind, not '%s'" % kind, content_path)
			return {}
		var content_result := ContentJsonType.read_json(content_path)
		if not content_result["ok"]:
			_fail_with(ERROR_INVALID_JSON, content_result, content_path)
			return {}
		if typeof(content_result["value"]) != TYPE_DICTIONARY:
			_fail(ERROR_SCHEMA_VIOLATION, "%s: expected an object" % kind, content_path)
			return {}
		var pack_document: Dictionary = content_result["value"]
		var kind_schema: Dictionary = schemas_by_kind[kind]
		var base_document: Dictionary = raw_by_kind[kind]
		var merge := _merge_pack_kind(pack_document, kind, kind_schema, base_document)
		if not merge["ok"]:
			var merge_code: String = merge["code"]
			_fail_with(merge_code, merge, content_path)
			return {}
	return {"id": pack_id, "version": pack_version}

## Validates one pack kind file and merges it into base_document[kind] in
## place. Every entry is checked against the base schema's entry schema. A new
## entry's id must not exist yet and lands after the existing entries; an
## override replaces the whole entry with its id, which must exist (else a
## dangling_reference). An id twice in one pack root (two new entries, two
## overrides, or one of each) is a schema_violation, like a base duplicate.
func _merge_pack_kind(pack_document: Dictionary, kind: String, schema: Dictionary, base_document: Dictionary) -> Dictionary:
	for key: String in pack_document.keys():
		if key != kind and key != PACK_OVERRIDES_FIELD:
			return _merge_error(ERROR_SCHEMA_VIOLATION, "%s: unexpected field '%s'" % [kind, key])
	var kind_property: Dictionary = schema["properties"][kind]
	var entry_schema: Dictionary = kind_property.get("items", {})
	var id_field: String = ID_FIELD_BY_KIND[kind]
	var entries: Array = base_document[kind]
	var index_by_id: Dictionary = {}
	for i in entries.size():
		index_by_id[_entry_id(entries[i] as Dictionary, id_field)] = i
	var seen_in_root: Dictionary = {}
	for field: String in [kind, PACK_OVERRIDES_FIELD]:
		var list_value: Variant = pack_document.get(field, [])
		if typeof(list_value) != TYPE_ARRAY:
			return _merge_error(ERROR_SCHEMA_VIOLATION, "%s.%s: expected an array" % [kind, field])
		var pack_entries: Array = list_value
		for i in pack_entries.size():
			var pack_entry: Variant = pack_entries[i]
			var check := _validate_node(pack_entry, entry_schema, "%s.%s[%d]" % [kind, field, i])
			if not check["ok"]:
				var check_message: String = check["message"]
				return _merge_error(ERROR_SCHEMA_VIOLATION, check_message)
			var id := _entry_id(pack_entry as Dictionary, id_field)
			if seen_in_root.has(id):
				return _merge_error(ERROR_SCHEMA_VIOLATION, "%s: duplicate id '%s'" % [kind, id])
			seen_in_root[id] = true
			if field == kind:
				if index_by_id.has(id):
					return _merge_error(ERROR_SCHEMA_VIOLATION,
						"%s: id '%s' already exists; list it under '%s' to replace it" % [kind, id, PACK_OVERRIDES_FIELD])
				index_by_id[id] = entries.size()
				entries.append(pack_entry)
			else:
				if not index_by_id.has(id):
					return _merge_error(ERROR_DANGLING_REFERENCE, "%s: override names an unknown id '%s'" % [kind, id])
				entries[index_by_id[id]] = pack_entry
	return {"ok": true}

func _merge_error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}

## _fail() with the message of a {ok: false, message} result.
func _fail_with(code: String, result: Dictionary, file: String) -> void:
	var message: String = result["message"]
	_fail(code, message, file)

## An entry's id as a String; entries are schema-validated, so id_field holds one.
func _entry_id(entry: Dictionary, id_field: String) -> String:
	var id: String = entry[id_field]
	return id

## The first id that appears twice in a collection's entry list, or "" when
## every id is unique.
func _first_duplicate_id(entries: Array, kind: String) -> String:
	var id_field: String = ID_FIELD_BY_KIND[kind]
	var seen: Dictionary = {}
	for entry: Dictionary in entries:
		var id := _entry_id(entry, id_field)
		if seen.has(id):
			return id
		seen[id] = true
	return ""

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

## The pack roots applied on top of the base bundle, in load order, as a
## frozen Array of frozen {id, version} Dictionaries; empty for the base only.
func packs() -> Array:
	if _packs.is_read_only():
		return _packs
	return _frozen_empty_array()

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

## Minimal JSON Schema subset sufficient for game/content/schemas/*: type,
## required, properties, additionalProperties, items, minItems, minLength,
## minimum, enum (A13: a value must equal one of the listed values, same JSON
## type). Not a general-purpose validator -- no $ref, oneOf, pattern, etc.
## additionalProperties is only ever enforced as a plain boolean false (an
## "unexpected field" rejection); a schema-valued additionalProperties (the
## standard JSON Schema way to constrain a dynamic-keyed object's values,
## used by factions.schema.json's "relations") is accepted but not applied
## (so the "enum" inside it stays inert), never a crash: the
## string-type and enum constraint it would have expressed for
## factions.json's "relations" values is instead enforced explicitly in
## _check_references(), which is reached for every relations value
## regardless of this validator's schema-valued additionalProperties support.
func _validate_node(value, schema: Dictionary, path: String) -> Dictionary:
	var type_field: Variant = schema.get("type", "")
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
			var additional_properties: Variant = schema.get("additionalProperties", true)
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
	var enum_values: Array = schema.get("enum", [])
	if schema.has("enum") and not _enum_has(enum_values, value):
		return {"ok": false, "message": "%s: value %s is not one of %s" % [path, value, schema["enum"]]}
	return {"ok": true}

## Whether value equals one of options with the same JSON type, so the string
## "1" never matches the number 1 (ints and floats are both JSON numbers).
func _enum_has(options: Array, value: Variant) -> bool:
	var value_is_number := typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT
	for option: Variant in options:
		var option_is_number := typeof(option) == TYPE_INT or typeof(option) == TYPE_FLOAT
		if value_is_number and option_is_number:
			var option_number: float = option
			var value_number: float = value
			if option_number == value_number:
				return true
		elif typeof(option) == typeof(value) and option == value:
			return true
	return false

## A schema's "type" may be an array of type names (e.g. ["string", "null"]),
## standard JSON Schema for "this field is one of several primitive shapes" --
## used by jobs.schema.json's effects.yields.find_table[].item, which is either an
## item id string or null (a bare "item": {} schema would silently accept
## any JSON value, so a wrong-typed item would only be caught later, by
## _check_job_effects(), and misreported as a dangling reference instead of a
## structural violation). value passes when it matches
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
## world_state.gd's TILE_* constants, which are not content-driven) or
## name a declared object kind; every faction's relations row
## (docs/decisions/014-factions-and-relations.md) must name only other
## declared faction ids, one row per other faction, no self-row, and each
## value must be a JSON string that is a known relation value -- checked in
## that order (own type before RelationsType.is_known_relation_value()) so a
## non-string JSON value (number, boolean, null, array, object) never reaches
## a GDScript String() conversion, which throws "Nonexistent 'String'
## constructor" for those types instead of returning gracefully (verified
## directly in this engine version); and an actor definition's optional
## faction_id (not yet declared by any real content/actors.json entry; see
## the ADR) must name a declared faction id when present. An object's
## optional build_cost is a list of {item, quantity}, one entry per required
## kind, naming the wood/stone/etc a construction site needs delivered
## before the object is placed (ADR 040) -- exactly the same shape of
## cross-file reference as a
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
			var relation_raw: Variant = relations[other_id]
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

	## F5 incidents (foundation-for-breadth.md F5): an incident's
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

## ADR 051 work effects: an unknown tile or item id is a dangling_reference; no "work" toil or
## find weights not 100, a schema_violation (yields.placement is the schema's enum).
func _check_job_effects(raw_by_kind: Dictionary) -> Array[String]:
	var known: Dictionary = {}
	for kind: String in ["tiles", "items"]:
		for entry: Dictionary in (raw_by_kind[kind][kind] as Array):
			var entry_id: String = entry["id"]
			known[kind + ":" + entry_id] = true
	for job: Dictionary in (raw_by_kind["jobs"]["jobs"] as Array):
		var effects: Dictionary = job.get("effects", {})
		if effects.is_empty():
			continue
		var bad := "job '%s' effects" % [job["kind"]]
		if not (job["toils"] as Array).has("work"):
			return [ERROR_SCHEMA_VIOLATION, bad + " need a 'work' toil"]
		for field: String in ["requires_tile", "set_tile"]:
			var tile_id: String = effects.get(field, "")
			if not tile_id.is_empty() and not known.has("tiles:" + tile_id):
				return [ERROR_DANGLING_REFERENCE, bad + ".%s names an unknown tile id '%s'" % [field, tile_id]]
		var yields: Dictionary = effects.get("yields", {})
		var named: Array = (yields.get("always", []) as Array).duplicate()
		named.append_array([effects["consumes"]] if effects.has("consumes") else [])
		var total := 0
		for find_entry: Dictionary in (yields.get("find_table", []) as Array):
			var weight: int = find_entry["weight"]
			total += weight
			if typeof(find_entry["item"]) == TYPE_STRING:
				named.append(find_entry["item"])
		for item_id: String in named:
			if not known.has("items:" + item_id):
				return [ERROR_DANGLING_REFERENCE, bad + " name an unknown item id '%s'" % item_id]
		if yields.has("find_table") and total != 100:
			return [ERROR_SCHEMA_VIOLATION, bad + ".yields.find_table weights must sum to 100, got %d" % total]
	return []

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

## A16 (ADR 053): each setup step carries exactly its SCENARIO_STEP_FIELDS (the schema subset has
## no per-variant lists), "when" needs the scenario's seed, every named object/item exists, and
## ground_items never names a tool (tools live in ToolItemStore, not the stackable item table).
func _check_scenarios(raw_by_kind: Dictionary) -> Dictionary:
	if not raw_by_kind.has("scenarios"):
		return {"ok": true}
	var known: Dictionary = {}
	for entry: Dictionary in (raw_by_kind["objects"]["objects"] as Array):
		known["object:%s" % entry["kind"]] = true
	for entry: Dictionary in (raw_by_kind["items"]["items"] as Array):
		known["item:%s" % entry["id"]] = entry.get("kind", "")
	for scenario: Dictionary in (raw_by_kind["scenarios"]["scenarios"] as Array):
		for step: Dictionary in (scenario["setup"] as Array):
			var where := "scenario '%s' step '%s'" % [scenario["id"], step["step"]]
			var fields: Array = (SCENARIO_STEP_FIELDS[step["step"]] as Array).duplicate()
			var present := step.keys().filter(func(field: Variant) -> bool: return not field in ["step", "when"])
			fields.sort()
			present.sort()
			if present != fields:
				return {"ok": false, "code": ERROR_SCHEMA_VIOLATION, "message": "%s must carry exactly the fields %s, got %s" % [where, fields, present]}
			if step.has("when") and not scenario.has("seed"):
				return {"ok": false, "code": ERROR_SCHEMA_VIOLATION, "message": "%s uses 'when' but the scenario has no seed" % where}
			for ref: String in _scenario_step_refs(step):
				if not known.has(ref):
					return {"ok": false, "code": ERROR_DANGLING_REFERENCE, "message": "%s names an unknown %s" % [where, ref.replace(":", " kind '") + "'"]}
			if step["step"] == "ground_items" and known["item:%s" % step["kind"]] == "tool":
				return {"ok": false, "code": ERROR_SCHEMA_VIOLATION, "message": "%s names tool item '%s'; tools are placed by needed_tools" % [where, step["kind"]]}
	return {"ok": true}

## The "object:<kind>"/"item:<id>" references one scenario setup step makes.
func _scenario_step_refs(step: Dictionary) -> Array[String]:
	var refs: Array[String] = []
	if step["step"] == "per_colonist_objects":
		refs.append("object:%s" % step["kind"])
	elif step["step"] == "ground_items":
		refs.append("item:%s" % step["kind"])
	for row: Dictionary in (step.get("rows", []) as Array):
		if row.has("door"):
			refs.append("object:%s" % row["door"])
		for entry: Dictionary in (row["objects"] as Array):
			refs.append("object:%s" % entry["kind"])
	return refs

func _is_collection_kind(kind: String) -> bool:
	return COLLECTION_KINDS.has(kind) or OPTIONAL_COLLECTION_KINDS.has(kind)

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
