extends SceneTree

## Covers issue #254 (F1 content registry, docs/architecture/foundation-for-
## breadth.md): 1) the real game/content/ bundle loads through
## ContentRegistry with every cross-reference (a job's needs_tool naming a
## declared tool item, a job's toils naming toils ToilExecutor implements, a
## need's source_kind naming either the reserved "tile" literal or a declared
## object kind) resolving cleanly, and its returned collections are frozen;
## 2) a small fixture bundle written to a user:// temp directory at runtime
## (following test_save_migration.gd's _write_v13_fixture() pattern), whose
## jobs.json deliberately names an unknown item id in needs_tool, fails
## construction with the expected typed, structured error instead of a silent
## default.

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")

const FIXTURE_DIR := "user://test-content-registry-fixture"
const FLOAT_INTEGER_FIXTURE_DIR := "user://test-content-registry-fixture-float-integer"
const MALFORMED_JSON_FIXTURE_DIR := "user://test-content-registry-fixture-malformed-json"
const EXTRA_KIND_CONTENT_DIR := "user://test-content-registry-fixture-extra-kind-content"
const EXTRA_KIND_SCHEMA_DIR := "user://test-content-registry-fixture-extra-kind-schemas"
const INVALID_MULTIPLIER_FIXTURE_DIR := "user://test-content-registry-fixture-invalid-multiplier"
const INCIDENT_DANGLING_FIXTURE_DIR := "user://test-content-registry-fixture-incident-dangling"
const YIELDS_WEIGHT_SUM_FIXTURE_DIR := "user://test-content-registry-fixture-yields-weight-sum"
const YIELDS_DANGLING_FIXTURE_DIR := "user://test-content-registry-fixture-yields-dangling"
const YIELDS_INVALID_ITEM_TYPE_FIXTURE_DIR := "user://test-content-registry-fixture-yields-invalid-item-type"
const WILD_TICKS_VALID_FIXTURE_DIR := "user://test-content-registry-fixture-wild-ticks-valid"
const WILD_TICKS_INVALID_FIXTURE_DIR := "user://test-content-registry-fixture-wild-ticks-invalid"
const BUILD_COST_DANGLING_FIXTURE_DIR := "user://test-content-registry-fixture-build-cost-dangling"
const MISSING_BUILD_COST_FIXTURE_DIR := "user://test-content-registry-fixture-missing-build-cost"

## ADR 025/026 (issue #359): tunables.wild.trench_climb_ticks must reject a
## non-integer, zero, and a negative value the same way combat's cooldown
## tunable already does.
const INVALID_WILD_TRENCH_CLIMB_TICKS := ["fast", 0, -1]

## Issue #293's needs.schema.json "number" case: a nonnumeric string, zero
## (exclusiveMinimum: 0 excludes the boundary itself), and a negative value
## must each fail schema validation rather than silently pass through as a
## multiplier _apply_need_effect() would later misuse.
const INVALID_BEDROOM_MULTIPLIERS := ["fast", 0, -1]

## Each entry replaces jobs.json's raw text with something that is not valid
## JSON per RFC 8259, even though a lenient hand-rolled parser could easily
## accept it: a leading zero ("01"), a decimal point with no digit after it
## ("1."), an exponent marker with no digit after it ("1e"), a "\u" escape
## whose 4 hex digits are not hex, and a raw (unescaped) control character
## inside a string literal.
const MALFORMED_JSON_JOBS_TEXT := [
	'{"jobs": [{"kind": "chop", "labour": "chop", "toils": [], "weight": 01}]}',
	'{"jobs": [{"kind": "chop", "labour": "chop", "toils": [], "weight": 1.}]}',
	'{"jobs": [{"kind": "chop", "labour": "chop", "toils": [], "weight": 1e}]}',
	'{"jobs": [{"kind": "chop", "labour": "chop", "toils": [], "label": "\\uZZZZ"}]}',
]

var _failed := false

func _init() -> void:
	_check_real_bundle_loads_and_resolves()
	_check_real_bundle_results_are_frozen()
	_check_unknown_kind_results_are_frozen()
	_check_fixture_with_dangling_reference_fails_construction()
	_check_fixture_with_float_integer_field_fails_construction()
	_check_fixtures_with_malformed_json_fail_construction()
	_check_extra_content_kind_with_matching_schema_is_not_ignored()
	_check_fixtures_with_invalid_bedroom_multiplier_fail_construction()
	_check_incident_fixtures_with_dangling_references_fail_construction()
	_check_fixture_with_yields_weight_sum_not_100_fails_construction()
	_check_fixture_with_yields_dangling_find_table_item_fails_construction()
	_check_fixture_with_yields_invalid_item_type_fails_construction()
	_check_fixture_with_valid_wild_trench_climb_ticks_constructs()
	_check_fixtures_with_invalid_wild_trench_climb_ticks_fail_construction()
	_check_fixture_with_build_cost_dangling_reference_fails_construction()
	_check_fixture_with_missing_build_cost_fails_construction()

	if _failed:
		quit(1)
		return
	print("test_content_registry: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## The real content/ bundle must load validly and every cross-reference this
## registry checks must resolve against it.
func _check_real_bundle_loads_and_resolves() -> void:
	var registry := ContentRegistryType.new()
	_expect(registry.is_valid(), "the real content bundle must load validly: %s" % registry.get_error())
	if not registry.is_valid():
		return

	_expect(registry.version() == "1.1.0", "manifest.json version must be exposed by version(), got '%s'" % registry.version())

	var dig := registry.get_entry("jobs", "dig")
	_expect(not dig.is_empty(), "jobs collection must contain 'dig'")
	_expect(String(dig.get("needs_tool", "")) == "pick", "dig's needs_tool must resolve to a declared tool item")

	# issue #357: dig's yields.always/find_table must resolve and its
	# find_table weights (5 + 20 + 10 + 10 + 55) must sum to 100.
	var dig_yields: Dictionary = dig.get("yields", {})
	_expect(not dig_yields.is_empty(), "dig must declare a yields field")
	_expect((dig_yields.get("always", []) as Array) == ["sand"], "dig's yields.always must be [\"sand\"]")
	var dig_find_table := (dig_yields.get("find_table", []) as Array)
	var dig_weight_total := 0
	for find_entry in dig_find_table:
		dig_weight_total += int((find_entry as Dictionary).get("weight", 0))
	_expect(dig_weight_total == 100, "dig's yields.find_table weights must sum to 100, got %d" % dig_weight_total)
	for find_entry in dig_find_table:
		var find_item = (find_entry as Dictionary).get("item")
		if find_item == null:
			continue
		_expect(not registry.get_entry("items", String(find_item)).is_empty(),
			"dig's yields.find_table item '%s' must resolve to a declared item" % find_item)

	var pick := registry.get_entry("items", "pick")
	_expect(not pick.is_empty() and String(pick.get("kind", "")) == "tool",
		"items collection must declare 'pick' as kind 'tool', the item dig's needs_tool names")

	for job in registry.list("jobs"):
		var tool_id := String(job.get("needs_tool", ""))
		if tool_id.is_empty():
			continue
		var tool_entry := registry.get_entry("items", tool_id)
		_expect(not tool_entry.is_empty() and String(tool_entry.get("kind", "")) == "tool",
			"job '%s' needs_tool '%s' must resolve to a declared tool item" % [job.get("kind"), tool_id])

	for object_entry in registry.list("objects"):
		_expect(object_entry.has("build_cost"), "object '%s' must declare a build_cost list" % object_entry.get("kind"))
		var build_cost: Array = object_entry.get("build_cost", [])
		for cost_entry in build_cost:
			var cost_item_id := String((cost_entry as Dictionary).get("item", ""))
			var cost_item_entry := registry.get_entry("items", cost_item_id)
			_expect(not cost_item_entry.is_empty(),
				"object '%s' build_cost.item '%s' must resolve to a declared item" % [object_entry.get("kind"), cost_item_id])

	for need in registry.list("needs"):
		var source_kind := String(need.get("source_kind", ""))
		var resolves := source_kind == "tile" or not registry.get_entry("objects", source_kind).is_empty()
		_expect(resolves, "need '%s' source_kind '%s' must resolve to 'tile' or a declared object kind" %
			[need.get("kind"), source_kind])

	_expect(registry.list("needs").size() == 3, "needs collection must contain exactly food/water/rest")
	_expect(registry.list("objects").size() > 0, "objects collection must not be empty")

	_expect(registry.list("actors").size() == 3, "actors collection must contain exactly colonist/wolf/trader")
	var colonist := registry.get_entry("actors", "colonist")
	_expect(not colonist.is_empty() and (colonist.get("components", []) as Array).has("worker"),
		"actors collection must declare 'colonist' with a worker component")

	_expect(registry.list("factions").size() == 6, "factions collection must contain exactly the six declared factions")
	var colony := registry.get_entry("factions", "colony")
	_expect(not colony.is_empty() and bool((colony.get("rules", {}) as Dictionary).get("may_be_ordered", false)),
		"factions collection must declare 'colony' with rules.may_be_ordered true")

	_expect(registry.list("incidents").size() == 5, "incidents collection must contain the four seed incidents plus migrant_joins")
	var wildlife_wander := registry.get_entry("incidents", "wildlife_wander")
	_expect(not wildlife_wander.is_empty() and String((wildlife_wander.get("spawn", {}) as Dictionary).get("actor_def", "")) == "wolf",
		"incidents collection must declare 'wildlife_wander' spawning a declared 'wolf' actor")

	_expect(registry.list("tiles").size() == 9, "tiles collection must contain exactly the 9 tile kinds")
	var trench_tile := registry.get_entry("tiles", "trench")
	var soil_tile := registry.get_entry("tiles", "soil")
	_expect(not trench_tile.is_empty() and bool(trench_tile.get("passable", false)) and not bool(trench_tile.get("diggable", true)),
		"tiles collection must declare 'trench' passable and not diggable")
	_expect(int(trench_tile.get("move_cost", -1)) == int(soil_tile.get("move_cost", -2))
			and int(trench_tile.get("move_ticks_per_tile", -1)) == int(soil_tile.get("move_ticks_per_tile", -2)),
		"trench's move_cost/move_ticks_per_tile must match soil's")
	var floor_tile := registry.get_entry("tiles", "floor")
	_expect(not floor_tile.is_empty() and bool(floor_tile.get("passable", false)) and int(floor_tile.get("move_cost", -1)) == 1,
		"tiles collection must declare 'floor' passable with move_cost 1")
	var rock_tile := registry.get_entry("tiles", "rock")
	_expect(not rock_tile.is_empty() and not bool(rock_tile.get("passable", true)),
		"tiles collection must declare 'rock' impassable")

	var mapgen := registry.document("mapgen")
	_expect(not mapgen.is_empty(), "document(\"mapgen\") must expose the mapgen document")
	# issue #300: spawn_area_width/height is now the clearing footprint size
	# WorldGenerator.place_spawn() searches for, and spawn_area_x/y is only its
	# last-resort documented fallback anchor -- neither is mirrored as a
	# compile-time WorldState constant any more (docs/decisions/020), so this
	# just checks the real content document declares both, positive.
	_expect(int(mapgen.get("spawn_area_width", -1)) > 0 and int(mapgen.get("spawn_area_height", -1)) > 0,
		"mapgen.json must declare a positive spawn_area_width/height")
	_expect(int(mapgen.get("colonist_count", -1)) == WorldStateType.COLONIST_COUNT,
		"mapgen.json's colonist_count must match WorldState.COLONIST_COUNT")

## get_entry()/list() results must be frozen: mutating them must not be
## possible without going through the registry.
func _check_real_bundle_results_are_frozen() -> void:
	var registry := ContentRegistryType.new()
	if not registry.is_valid():
		_fail("the real content bundle must load validly for the freeze check")
		return

	var dig := registry.get_entry("jobs", "dig")
	_expect(dig.is_read_only(), "get_entry() must return a read-only Dictionary")

	var toils = dig.get("toils")
	_expect(toils is Array and (toils as Array).is_read_only(), "a nested array inside a frozen entry must itself be read-only")

	var jobs_list := registry.list("jobs")
	_expect(jobs_list.is_read_only(), "list() must return a read-only Array")
	for entry in jobs_list:
		_expect((entry as Dictionary).is_read_only(), "every entry inside list()'s result must be read-only")

	var mapgen := registry.document("mapgen")
	_expect(mapgen.is_read_only(), "document(\"mapgen\") must return a read-only Dictionary")

## get_entry() for an unknown kind, get_entry() for a known kind but unknown
## id, and list() for an unknown kind must all still return a read-only
## result -- review round 4's finding that these "not found" paths returned a
## plain mutable {}/[] rather than the frozen empty value every other
## get_entry()/list() result is.
func _check_unknown_kind_results_are_frozen() -> void:
	var registry := ContentRegistryType.new()
	if not registry.is_valid():
		_fail("the real content bundle must load validly for the unknown-kind freeze check")
		return

	var unknown_kind_entry := registry.get_entry("no_such_kind", "dig")
	_expect(unknown_kind_entry.is_empty(), "get_entry() for an unknown kind must be empty")
	_expect(unknown_kind_entry.is_read_only(), "get_entry() for an unknown kind must return a read-only Dictionary")

	var unknown_id_entry := registry.get_entry("jobs", "no_such_id")
	_expect(unknown_id_entry.is_empty(), "get_entry() for an unknown id must be empty")
	_expect(unknown_id_entry.is_read_only(), "get_entry() for an unknown id must return a read-only Dictionary")

	var unknown_kind_list := registry.list("no_such_kind")
	_expect(unknown_kind_list.is_empty(), "list() for an unknown kind must be empty")
	_expect(unknown_kind_list.is_read_only(), "list() for an unknown kind must return a read-only Array")

	var unknown_document := registry.document("no_such_kind")
	_expect(unknown_document.is_empty(), "document() for an unknown kind must be empty")
	_expect(unknown_document.is_read_only(), "document() for an unknown kind must return a read-only Dictionary")

## A fixture bundle whose jobs.json names an unknown item id in needs_tool
## must fail construction with a typed dangling_reference error, never a
## silently-applied default (an empty/partial registry that looks usable).
func _check_fixture_with_dangling_reference_fails_construction() -> void:
	_write_fixture_bundle()
	var registry := ContentRegistryType.new(FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)
	_cleanup_dir(FIXTURE_DIR)

	_expect(not registry.is_valid(), "a fixture bundle with a dangling reference must fail construction")
	var error := registry.get_error()
	_expect(error.get("code") == ContentRegistryType.ERROR_DANGLING_REFERENCE,
		"the fixture's error code must be typed as dangling_reference, got %s" % error)
	_expect(String(error.get("file", "")).ends_with("jobs.json"),
		"the fixture's error must name jobs.json as the offending file, got %s" % error)
	_expect(registry.list("jobs").is_empty(), "an invalid registry must expose no jobs, never a partial default")
	_expect(registry.version() == "", "an invalid registry must expose no manifest version, never a partial default")

## issue #278/round-3: a fixture bundle whose objects.json declares a
## build_cost naming an unknown item id must fail construction with the typed
## dangling_reference error naming objects.json, exactly like needs_tool
## above -- never load as valid content that only surfaces at play time as a
## runtime blocked_missing_input.
func _check_fixture_with_build_cost_dangling_reference_fails_construction() -> void:
	_write_build_cost_dangling_fixture_bundle()
	var registry := ContentRegistryType.new(BUILD_COST_DANGLING_FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)
	_cleanup_dir(BUILD_COST_DANGLING_FIXTURE_DIR)

	_expect(not registry.is_valid(), "a build_cost.item naming an unknown item id must fail construction")
	var error := registry.get_error()
	_expect(error.get("code") == ContentRegistryType.ERROR_DANGLING_REFERENCE,
		"the build_cost dangling reference error must be typed as dangling_reference, got %s" % error)
	_expect(String(error.get("file", "")).ends_with("objects.json"),
		"the build_cost dangling reference error must name objects.json as the offending file, got %s" % error)
	_expect(String(error.get("message", "")).contains("does_not_exist"),
		"the build_cost dangling reference error must name the dangling id, got %s" % error)

## Same otherwise-valid bundle as _write_fixture_bundle(), except objects.json's
## "wall" entry declares a build_cost list whose second entry names an item id
## no items.json entry declares (the first entry, "wood", DOES resolve --
## issue #403's build_cost is now a list, and this proves the dangling check
## walks every position, not just index 0), and jobs.json's "chop" entry has
## no needs_tool (so the only dangling reference in this bundle is the one
## under test).
func _write_build_cost_dangling_fixture_bundle() -> void:
	var dir := DirAccess.open("user://")
	if not dir.dir_exists(BUILD_COST_DANGLING_FIXTURE_DIR):
		dir.make_dir_recursive(BUILD_COST_DANGLING_FIXTURE_DIR)

	_write_json(BUILD_COST_DANGLING_FIXTURE_DIR + "/manifest.json", {"version": "0.0.1-fixture"})
	_write_json(BUILD_COST_DANGLING_FIXTURE_DIR + "/items.json", {"items": [{"id": "axe", "kind": "tool"}, {"id": "wood", "kind": "material"}]})
	_write_json(BUILD_COST_DANGLING_FIXTURE_DIR + "/objects.json", {"objects": [
		{"kind": "bed", "passable": true, "move_cost": 3, "is_door": false, "footprint": [1, 1], "rotatable": false, "build_ticks": 40, "max_builders": 1, "build_cost": []},
		{"kind": "wall", "passable": false, "move_cost": 0, "is_door": false, "footprint": [1, 1], "rotatable": false, "build_ticks": 40, "max_builders": 1, "build_cost": [{"item": "wood", "quantity": 1}, {"item": "does_not_exist", "quantity": 1}]},
	]})
	_write_json(BUILD_COST_DANGLING_FIXTURE_DIR + "/needs.json", {"needs": [
		{"kind": "rest", "rate_per_day": 80, "warn": 50, "urgent": 25, "critical": 10, "restore": 100, "source_kind": "bed", "full": 100, "job_priority": 1, "retry_base_ticks": 10, "retry_cap_ticks": 40},
	]})
	_write_json(BUILD_COST_DANGLING_FIXTURE_DIR + "/calendar.json", {"day_length_ticks": 100, "windows": []})
	_write_json(BUILD_COST_DANGLING_FIXTURE_DIR + "/jobs.json", {"jobs": [
		{"kind": "chop", "labour": "chop", "toils": ["reserve", "go_to", "work", "release_all"]},
	]})
	_write_required_tiles_and_mapgen(BUILD_COST_DANGLING_FIXTURE_DIR)

## Round-6 finding: build_cost is a required field on every objects.json row
## (not just the buildable kinds), so a row omitting it entirely must fail
## construction typed schema_violation naming objects.json, exactly like any
## other missing-required-field case -- never silently load with an implied
## empty cost.
func _check_fixture_with_missing_build_cost_fails_construction() -> void:
	_write_missing_build_cost_fixture_bundle()
	var registry := ContentRegistryType.new(MISSING_BUILD_COST_FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)
	_cleanup_dir(MISSING_BUILD_COST_FIXTURE_DIR)

	_expect(not registry.is_valid(), "an objects.json row with no build_cost field must fail construction")
	var error := registry.get_error()
	_expect(error.get("code") == ContentRegistryType.ERROR_SCHEMA_VIOLATION,
		"the missing build_cost error must be typed as schema_violation, got %s" % error)
	_expect(String(error.get("file", "")).ends_with("objects.json"),
		"the missing build_cost error must name objects.json as the offending file, got %s" % error)
	_expect(String(error.get("message", "")).contains("build_cost"),
		"the missing build_cost error must name the missing field, got %s" % error)

## Same otherwise-valid bundle as _write_fixture_bundle(), except objects.json's
## "bed" entry declares every other required field (footprint/rotatable/
## build_ticks/max_builders) but omits build_cost entirely.
func _write_missing_build_cost_fixture_bundle() -> void:
	var dir := DirAccess.open("user://")
	if not dir.dir_exists(MISSING_BUILD_COST_FIXTURE_DIR):
		dir.make_dir_recursive(MISSING_BUILD_COST_FIXTURE_DIR)

	_write_json(MISSING_BUILD_COST_FIXTURE_DIR + "/manifest.json", {"version": "0.0.1-fixture"})
	_write_json(MISSING_BUILD_COST_FIXTURE_DIR + "/items.json", {"items": [{"id": "axe", "kind": "tool"}]})
	_write_json(MISSING_BUILD_COST_FIXTURE_DIR + "/objects.json", {"objects": [
		{"kind": "bed", "passable": true, "move_cost": 3, "is_door": false, "footprint": [1, 1], "rotatable": false, "build_ticks": 40, "max_builders": 1},
	]})
	_write_json(MISSING_BUILD_COST_FIXTURE_DIR + "/needs.json", {"needs": [
		{"kind": "rest", "rate_per_day": 80, "warn": 50, "urgent": 25, "critical": 10, "restore": 100, "source_kind": "bed", "full": 100, "job_priority": 1, "retry_base_ticks": 10, "retry_cap_ticks": 40},
	]})
	_write_json(MISSING_BUILD_COST_FIXTURE_DIR + "/calendar.json", {"day_length_ticks": 100, "windows": []})
	_write_json(MISSING_BUILD_COST_FIXTURE_DIR + "/jobs.json", {"jobs": [
		{"kind": "chop", "labour": "chop", "toils": ["reserve", "go_to", "work", "release_all"]},
	]})
	_write_required_tiles_and_mapgen(MISSING_BUILD_COST_FIXTURE_DIR)

## A fixture bundle whose objects.json gives move_cost (schema type
## "integer") the float literal 3.0 instead of an integer literal must fail
## construction with a typed schema_violation error: JSON Schema's "integer"
## type rejects a floating-point value even when it is mathematically whole,
## and Godot's own JSON.parse_string() cannot see this distinction at all
## (it always returns TYPE_FLOAT for every JSON number), so this only proves
## anything if written through JSON.stringify()'s int/float-preserving text
## output, read back through the registry's own parser.
func _check_fixture_with_float_integer_field_fails_construction() -> void:
	_write_float_integer_fixture_bundle()
	var registry := ContentRegistryType.new(FLOAT_INTEGER_FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)
	_cleanup_dir(FLOAT_INTEGER_FIXTURE_DIR)

	_expect(not registry.is_valid(), "a fixture bundle with a float-valued integer field must fail construction")
	var error := registry.get_error()
	_expect(error.get("code") == ContentRegistryType.ERROR_SCHEMA_VIOLATION,
		"the fixture's error code must be typed as schema_violation, got %s" % error)
	_expect(String(error.get("file", "")).ends_with("objects.json"),
		"the fixture's error must name objects.json as the offending file, got %s" % error)

## F5 (issue #294): an incidents.json row whose spawn.actor_def names an
## undeclared actor id, and one whose faction names an undeclared faction id,
## must each fail construction with the typed dangling_reference error naming
## incidents.json -- never a silent skip of the row.
func _check_incident_fixtures_with_dangling_references_fail_construction() -> void:
	var cases := {
		"actor_def": {"id": "bad_actor", "faction": "wildlife", "min_day": 1, "weight": 1, "cooldown_days": 1,
			"spawn": {"actor_def": "does_not_exist", "count": 1, "edge": "north", "wait_ticks": 1}},
		"faction": {"id": "bad_faction", "faction": "does_not_exist", "min_day": 1, "weight": 1, "cooldown_days": 1,
			"spawn": {"actor_def": "colonist", "count": 1, "edge": "north", "wait_ticks": 1}},
	}
	for case_name in cases:
		_write_incident_dangling_fixture_bundle(cases[case_name])
		var registry := ContentRegistryType.new(INCIDENT_DANGLING_FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)
		_cleanup_dir(INCIDENT_DANGLING_FIXTURE_DIR)
		_expect(not registry.is_valid(), "an incidents.json row with an unknown %s must fail construction" % case_name)
		var error := registry.get_error()
		_expect(error.get("code") == ContentRegistryType.ERROR_DANGLING_REFERENCE,
			"the unknown-%s error must be typed as dangling_reference, got %s" % [case_name, error])
		_expect(String(error.get("file", "")).ends_with("incidents.json"),
			"the unknown-%s error must name incidents.json as the offending file, got %s" % [case_name, error])
		_expect(String(error.get("message", "")).contains("does_not_exist"),
			"the unknown-%s error must name the dangling id, got %s" % [case_name, error])
		_expect(registry.list("incidents").is_empty(), "an invalid registry must expose no incidents, never a partial default")

## issue #357: a jobs.json yields.find_table whose weights do not sum to 100
## must fail construction typed schema_violation, naming jobs.json -- the
## cross-field arithmetic rule _validate_node's minimal JSON Schema subset
## cannot express (see ContentRegistry._check_job_yields()).
func _check_fixture_with_yields_weight_sum_not_100_fails_construction() -> void:
	_write_yields_weight_sum_fixture_bundle()
	var registry := ContentRegistryType.new(YIELDS_WEIGHT_SUM_FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)
	_cleanup_dir(YIELDS_WEIGHT_SUM_FIXTURE_DIR)

	_expect(not registry.is_valid(), "a yields.find_table whose weights do not sum to 100 must fail construction")
	var error := registry.get_error()
	_expect(error.get("code") == ContentRegistryType.ERROR_SCHEMA_VIOLATION,
		"the weight-sum error must be typed as schema_violation, got %s" % error)
	_expect(String(error.get("file", "")).ends_with("jobs.json"),
		"the weight-sum error must name jobs.json as the offending file, got %s" % error)

## Same otherwise-valid bundle as _write_fixture_bundle(), except jobs.json's
## "chop" entry declares a yields.find_table whose weights (50 + 40) sum to 90,
## not 100.
func _write_yields_weight_sum_fixture_bundle() -> void:
	var dir := DirAccess.open("user://")
	if not dir.dir_exists(YIELDS_WEIGHT_SUM_FIXTURE_DIR):
		dir.make_dir_recursive(YIELDS_WEIGHT_SUM_FIXTURE_DIR)

	_write_json(YIELDS_WEIGHT_SUM_FIXTURE_DIR + "/manifest.json", {"version": "0.0.1-fixture"})
	_write_json(YIELDS_WEIGHT_SUM_FIXTURE_DIR + "/items.json", {"items": [{"id": "axe", "kind": "tool"}, {"id": "sand", "kind": "material"}]})
	_write_json(YIELDS_WEIGHT_SUM_FIXTURE_DIR + "/objects.json", {"objects": [
		{"kind": "bed", "passable": true, "move_cost": 3, "is_door": false, "footprint": [1, 1], "rotatable": false, "build_ticks": 40, "max_builders": 1, "build_cost": []},
	]})
	_write_json(YIELDS_WEIGHT_SUM_FIXTURE_DIR + "/needs.json", {"needs": [
		{"kind": "rest", "rate_per_day": 80, "warn": 50, "urgent": 25, "critical": 10, "restore": 100, "source_kind": "bed", "full": 100, "job_priority": 1, "retry_base_ticks": 10, "retry_cap_ticks": 40},
	]})
	_write_json(YIELDS_WEIGHT_SUM_FIXTURE_DIR + "/calendar.json", {"day_length_ticks": 100, "windows": []})
	_write_json(YIELDS_WEIGHT_SUM_FIXTURE_DIR + "/jobs.json", {"jobs": [
		{"kind": "chop", "labour": "chop", "toils": ["reserve", "go_to", "work", "release_all"],
			"yields": {"always": ["sand"], "find_table": [{"item": "sand", "weight": 50}, {"item": null, "weight": 40}]}},
	]})
	_write_required_tiles_and_mapgen(YIELDS_WEIGHT_SUM_FIXTURE_DIR)

## issue #357: a jobs.json yields.find_table naming an item id absent from
## items.json must fail construction typed dangling_reference, naming
## jobs.json and the dangling id, matching every other cross-file check.
func _check_fixture_with_yields_dangling_find_table_item_fails_construction() -> void:
	_write_yields_dangling_fixture_bundle()
	var registry := ContentRegistryType.new(YIELDS_DANGLING_FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)
	_cleanup_dir(YIELDS_DANGLING_FIXTURE_DIR)

	_expect(not registry.is_valid(), "a yields.find_table naming an unknown item id must fail construction")
	var error := registry.get_error()
	_expect(error.get("code") == ContentRegistryType.ERROR_DANGLING_REFERENCE,
		"the dangling find_table item error must be typed as dangling_reference, got %s" % error)
	_expect(String(error.get("file", "")).ends_with("jobs.json"),
		"the dangling find_table item error must name jobs.json as the offending file, got %s" % error)
	_expect(String(error.get("message", "")).contains("does_not_exist"),
		"the dangling find_table item error must name the dangling id, got %s" % error)

## Same otherwise-valid bundle as _write_fixture_bundle(), except jobs.json's
## "chop" entry declares a yields.find_table naming "does_not_exist", which no
## items.json entry declares.
func _write_yields_dangling_fixture_bundle() -> void:
	var dir := DirAccess.open("user://")
	if not dir.dir_exists(YIELDS_DANGLING_FIXTURE_DIR):
		dir.make_dir_recursive(YIELDS_DANGLING_FIXTURE_DIR)

	_write_json(YIELDS_DANGLING_FIXTURE_DIR + "/manifest.json", {"version": "0.0.1-fixture"})
	_write_json(YIELDS_DANGLING_FIXTURE_DIR + "/items.json", {"items": [{"id": "axe", "kind": "tool"}]})
	_write_json(YIELDS_DANGLING_FIXTURE_DIR + "/objects.json", {"objects": [
		{"kind": "bed", "passable": true, "move_cost": 3, "is_door": false, "footprint": [1, 1], "rotatable": false, "build_ticks": 40, "max_builders": 1, "build_cost": []},
	]})
	_write_json(YIELDS_DANGLING_FIXTURE_DIR + "/needs.json", {"needs": [
		{"kind": "rest", "rate_per_day": 80, "warn": 50, "urgent": 25, "critical": 10, "restore": 100, "source_kind": "bed", "full": 100, "job_priority": 1, "retry_base_ticks": 10, "retry_cap_ticks": 40},
	]})
	_write_json(YIELDS_DANGLING_FIXTURE_DIR + "/calendar.json", {"day_length_ticks": 100, "windows": []})
	_write_json(YIELDS_DANGLING_FIXTURE_DIR + "/jobs.json", {"jobs": [
		{"kind": "chop", "labour": "chop", "toils": ["reserve", "go_to", "work", "release_all"],
			"yields": {"always": [], "find_table": [{"item": "does_not_exist", "weight": 100}]}},
	]})
	_write_required_tiles_and_mapgen(YIELDS_DANGLING_FIXTURE_DIR)

## Same otherwise-valid bundle as _write_float_integer_fixture_bundle() (an
## integer move_cost), with incidents.json replaced by the single given row.
func _write_incident_dangling_fixture_bundle(incident_row: Dictionary) -> void:
	var dir := DirAccess.open("user://")
	if not dir.dir_exists(INCIDENT_DANGLING_FIXTURE_DIR):
		dir.make_dir_recursive(INCIDENT_DANGLING_FIXTURE_DIR)
	_write_json(INCIDENT_DANGLING_FIXTURE_DIR + "/manifest.json", {"version": "0.0.1-fixture"})
	_write_json(INCIDENT_DANGLING_FIXTURE_DIR + "/items.json", {"items": [{"id": "axe", "kind": "tool"}]})
	_write_json(INCIDENT_DANGLING_FIXTURE_DIR + "/objects.json", {"objects": [
		{"kind": "bed", "passable": true, "move_cost": 3, "is_door": false, "footprint": [1, 1], "rotatable": false, "build_ticks": 40, "max_builders": 1, "build_cost": []},
	]})
	_write_json(INCIDENT_DANGLING_FIXTURE_DIR + "/needs.json", {"needs": [
		{"kind": "rest", "rate_per_day": 80, "warn": 50, "urgent": 25, "critical": 10, "restore": 100, "source_kind": "bed", "full": 100, "job_priority": 1, "retry_base_ticks": 10, "retry_cap_ticks": 40},
	]})
	_write_json(INCIDENT_DANGLING_FIXTURE_DIR + "/calendar.json", {"day_length_ticks": 100, "windows": []})
	_write_json(INCIDENT_DANGLING_FIXTURE_DIR + "/jobs.json", {"jobs": [
		{"kind": "chop", "labour": "chop", "toils": ["reserve", "go_to", "work", "release_all"]},
	]})
	_write_required_tiles_and_mapgen(INCIDENT_DANGLING_FIXTURE_DIR)
	_write_json(INCIDENT_DANGLING_FIXTURE_DIR + "/incidents.json", {"incidents": [incident_row]})

## issue #357 review round 1: a jobs.json yields.find_table entry whose "item"
## is neither a string nor null (a number here) must fail construction typed
## schema_violation, not dangling_reference -- jobs.schema.json's "item":
## {"type": ["string", "null"]} constraint (ContentRegistry._validate_node's
## union-type support) must catch this structurally, before ContentRegistry
## ever reaches its dangling-reference cross-check in _check_references().
func _check_fixture_with_yields_invalid_item_type_fails_construction() -> void:
	_write_yields_invalid_item_type_fixture_bundle()
	var registry := ContentRegistryType.new(YIELDS_INVALID_ITEM_TYPE_FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)
	_cleanup_dir(YIELDS_INVALID_ITEM_TYPE_FIXTURE_DIR)

	_expect(not registry.is_valid(), "a yields.find_table item that is neither a string nor null must fail construction")
	var error := registry.get_error()
	_expect(error.get("code") == ContentRegistryType.ERROR_SCHEMA_VIOLATION,
		"the invalid item type error must be typed as schema_violation, got %s" % error)
	_expect(String(error.get("file", "")).ends_with("jobs.json"),
		"the invalid item type error must name jobs.json as the offending file, got %s" % error)

## Same otherwise-valid bundle as _write_fixture_bundle(), except jobs.json's
## "chop" entry declares a yields.find_table whose single entry's "item" is
## the number 5, not a string or null.
func _write_yields_invalid_item_type_fixture_bundle() -> void:
	var dir := DirAccess.open("user://")
	if not dir.dir_exists(YIELDS_INVALID_ITEM_TYPE_FIXTURE_DIR):
		dir.make_dir_recursive(YIELDS_INVALID_ITEM_TYPE_FIXTURE_DIR)

	_write_json(YIELDS_INVALID_ITEM_TYPE_FIXTURE_DIR + "/manifest.json", {"version": "0.0.1-fixture"})
	_write_json(YIELDS_INVALID_ITEM_TYPE_FIXTURE_DIR + "/items.json", {"items": [{"id": "axe", "kind": "tool"}]})
	_write_json(YIELDS_INVALID_ITEM_TYPE_FIXTURE_DIR + "/objects.json", {"objects": [
		{"kind": "bed", "passable": true, "move_cost": 3, "is_door": false, "footprint": [1, 1], "rotatable": false, "build_ticks": 40, "max_builders": 1, "build_cost": []},
	]})
	_write_json(YIELDS_INVALID_ITEM_TYPE_FIXTURE_DIR + "/needs.json", {"needs": [
		{"kind": "rest", "rate_per_day": 80, "warn": 50, "urgent": 25, "critical": 10, "restore": 100, "source_kind": "bed", "full": 100, "job_priority": 1, "retry_base_ticks": 10, "retry_cap_ticks": 40},
	]})
	_write_json(YIELDS_INVALID_ITEM_TYPE_FIXTURE_DIR + "/calendar.json", {"day_length_ticks": 100, "windows": []})
	_write_json(YIELDS_INVALID_ITEM_TYPE_FIXTURE_DIR + "/jobs.json", {"jobs": [
		{"kind": "chop", "labour": "chop", "toils": ["reserve", "go_to", "work", "release_all"],
			"yields": {"always": [], "find_table": [{"item": 5, "weight": 100}]}},
	]})
	_write_required_tiles_and_mapgen(YIELDS_INVALID_ITEM_TYPE_FIXTURE_DIR)

## Same otherwise-valid bundle as _write_fixture_bundle(), except objects.json's
## "bed" gives move_cost the float literal 3.0 (JSON.stringify(3.0) => "3.0")
## instead of the integer literal 3.
func _write_float_integer_fixture_bundle() -> void:
	var dir := DirAccess.open("user://")
	if not dir.dir_exists(FLOAT_INTEGER_FIXTURE_DIR):
		dir.make_dir_recursive(FLOAT_INTEGER_FIXTURE_DIR)

	_write_json(FLOAT_INTEGER_FIXTURE_DIR + "/manifest.json", {"version": "0.0.1-fixture"})
	_write_json(FLOAT_INTEGER_FIXTURE_DIR + "/items.json", {"items": [{"id": "axe", "kind": "tool"}]})
	_write_json(FLOAT_INTEGER_FIXTURE_DIR + "/objects.json", {"objects": [
		{"kind": "bed", "passable": true, "move_cost": 3.0, "is_door": false},
	]})
	_write_json(FLOAT_INTEGER_FIXTURE_DIR + "/needs.json", {"needs": [
		{"kind": "rest", "rate_per_day": 80, "warn": 50, "urgent": 25, "critical": 10, "restore": 100, "source_kind": "bed", "full": 100, "job_priority": 1, "retry_base_ticks": 10, "retry_cap_ticks": 40},
	]})
	_write_json(FLOAT_INTEGER_FIXTURE_DIR + "/calendar.json", {"day_length_ticks": 100, "windows": []})
	_write_json(FLOAT_INTEGER_FIXTURE_DIR + "/jobs.json", {"jobs": [
		{"kind": "chop", "labour": "chop", "toils": ["reserve", "go_to", "work", "release_all"]},
	]})
	_write_required_tiles_and_mapgen(FLOAT_INTEGER_FIXTURE_DIR)

## needs.schema.json's bedroom_rest_multiplier declares {"type": "number",
## "exclusiveMinimum": 0}; each case below swaps in a value that schema
## should reject, and each must fail construction typed schema_violation
## against needs.json, not silently load and reach _apply_need_effect().
func _check_fixtures_with_invalid_bedroom_multiplier_fail_construction() -> void:
	for i in INVALID_BEDROOM_MULTIPLIERS.size():
		var multiplier = INVALID_BEDROOM_MULTIPLIERS[i]
		_write_invalid_multiplier_fixture_bundle(multiplier)
		var registry := ContentRegistryType.new(INVALID_MULTIPLIER_FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)
		_cleanup_dir(INVALID_MULTIPLIER_FIXTURE_DIR)

		_expect(not registry.is_valid(), "bedroom_rest_multiplier %s must fail construction" % multiplier)
		var error := registry.get_error()
		_expect(error.get("code") == ContentRegistryType.ERROR_SCHEMA_VIOLATION,
			"bedroom_rest_multiplier %s must be typed as schema_violation, got %s" % [multiplier, error])
		_expect(String(error.get("file", "")).ends_with("needs.json"),
			"bedroom_rest_multiplier %s's error must name needs.json, got %s" % [multiplier, error])

## Same otherwise-valid bundle as _write_fixture_bundle(), except the rest
## need entry's bedroom_rest_multiplier is the given (invalid) value.
func _write_invalid_multiplier_fixture_bundle(multiplier) -> void:
	var dir := DirAccess.open("user://")
	if not dir.dir_exists(INVALID_MULTIPLIER_FIXTURE_DIR):
		dir.make_dir_recursive(INVALID_MULTIPLIER_FIXTURE_DIR)

	_write_json(INVALID_MULTIPLIER_FIXTURE_DIR + "/manifest.json", {"version": "0.0.1-fixture"})
	_write_json(INVALID_MULTIPLIER_FIXTURE_DIR + "/items.json", {"items": [{"id": "axe", "kind": "tool"}]})
	_write_json(INVALID_MULTIPLIER_FIXTURE_DIR + "/objects.json", {"objects": [
		{"kind": "bed", "passable": true, "move_cost": 3, "is_door": false, "footprint": [1, 1], "rotatable": false, "build_ticks": 40, "max_builders": 1, "build_cost": []},
	]})
	_write_json(INVALID_MULTIPLIER_FIXTURE_DIR + "/needs.json", {"needs": [
		{"kind": "rest", "rate_per_day": 80, "warn": 50, "urgent": 25, "critical": 10, "restore": 100, "source_kind": "bed", "full": 100, "job_priority": 1, "retry_base_ticks": 10, "retry_cap_ticks": 40, "bedroom_rest_multiplier": multiplier},
	]})
	_write_json(INVALID_MULTIPLIER_FIXTURE_DIR + "/calendar.json", {"day_length_ticks": 100, "windows": []})
	_write_json(INVALID_MULTIPLIER_FIXTURE_DIR + "/jobs.json", {"jobs": [
		{"kind": "chop", "labour": "chop", "toils": ["reserve", "go_to", "work", "release_all"]},
	]})
	_write_required_tiles_and_mapgen(INVALID_MULTIPLIER_FIXTURE_DIR)

## ADR 025/026 (issue #359): a non-default tunables.wild.trench_climb_ticks
## (99, not WorldState.DEFAULT_TRENCH_CLIMB_TICKS's 40) must construct
## cleanly -- proves the schema/ActorWild.validate() path accepts the real
## requested shape, not just the specific default value content/actors.json
## happens to use today.
func _check_fixture_with_valid_wild_trench_climb_ticks_constructs() -> void:
	_write_wild_ticks_fixture_bundle(WILD_TICKS_VALID_FIXTURE_DIR, 99)
	var registry := ContentRegistryType.new(WILD_TICKS_VALID_FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)
	_cleanup_dir(WILD_TICKS_VALID_FIXTURE_DIR)

	_expect(registry.is_valid(), "a non-default tunables.wild.trench_climb_ticks must construct cleanly, got %s" % registry.get_error())

## ADR 025/026 (issue #359): a non-integer, zero, or negative
## tunables.wild.trench_climb_ticks must each fail construction typed
## schema_violation against actors.json, mirroring
## _check_fixtures_with_invalid_bedroom_multiplier_fail_construction().
func _check_fixtures_with_invalid_wild_trench_climb_ticks_fail_construction() -> void:
	for i in INVALID_WILD_TRENCH_CLIMB_TICKS.size():
		var ticks = INVALID_WILD_TRENCH_CLIMB_TICKS[i]
		_write_wild_ticks_fixture_bundle(WILD_TICKS_INVALID_FIXTURE_DIR, ticks)
		var registry := ContentRegistryType.new(WILD_TICKS_INVALID_FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)
		_cleanup_dir(WILD_TICKS_INVALID_FIXTURE_DIR)

		_expect(not registry.is_valid(), "tunables.wild.trench_climb_ticks %s must fail construction" % ticks)
		var error := registry.get_error()
		_expect(error.get("code") == ContentRegistryType.ERROR_SCHEMA_VIOLATION,
			"tunables.wild.trench_climb_ticks %s must be typed as schema_violation, got %s" % [ticks, error])
		_expect(String(error.get("file", "")).ends_with("actors.json"),
			"tunables.wild.trench_climb_ticks %s's error must name actors.json, got %s" % [ticks, error])

## Same otherwise-valid bundle _write_required_tiles_and_mapgen() writes,
## except actors.json gains a second, wild-only actor def whose
## tunables.wild.trench_climb_ticks is the given value.
func _write_wild_ticks_fixture_bundle(dir: String, ticks) -> void:
	var dir_access := DirAccess.open("user://")
	if not dir_access.dir_exists(dir):
		dir_access.make_dir_recursive(dir)

	_write_json(dir + "/manifest.json", {"version": "0.0.1-fixture"})
	_write_json(dir + "/items.json", {"items": [{"id": "axe", "kind": "tool"}]})
	_write_json(dir + "/objects.json", {"objects": [
		{"kind": "bed", "passable": true, "move_cost": 3, "is_door": false, "footprint": [1, 1], "rotatable": false, "build_ticks": 40, "max_builders": 1, "build_cost": []},
	]})
	_write_json(dir + "/needs.json", {"needs": [
		{"kind": "rest", "rate_per_day": 80, "warn": 50, "urgent": 25, "critical": 10, "restore": 100, "source_kind": "bed", "full": 100, "job_priority": 1, "retry_base_ticks": 10, "retry_cap_ticks": 40},
	]})
	_write_json(dir + "/calendar.json", {"day_length_ticks": 100, "windows": []})
	_write_json(dir + "/jobs.json", {"jobs": [
		{"kind": "chop", "labour": "chop", "toils": ["reserve", "go_to", "work", "release_all"]},
	]})
	_write_required_tiles_and_mapgen(dir)
	_write_json(dir + "/actors.json", {"actors": [
		{"id": "colonist", "components": ["mover"], "tunables": {"mover": {"speed": 1}}},
		{"id": "wolf", "components": ["wild"], "tunables": {"wild": {"trench_climb_ticks": ticks}}},
	]})

## Every JSON malformation named in review round 2 that this parser must
## reject rather than silently accept: a leading zero, a decimal point or
## exponent marker with no digit after it, an invalid hex escape, and a raw
## (unescaped) control character in a string literal. Each case swaps an
## otherwise-valid bundle's jobs.json for hand-written text (not run through
## JSON.stringify(), which cannot itself produce malformed JSON) that a
## lenient parser could still accept.
func _check_fixtures_with_malformed_json_fail_construction() -> void:
	var cases: Array = MALFORMED_JSON_JOBS_TEXT.duplicate()
	cases.append('{"jobs": [{"kind": "chop", "labour": "chop", "toils": [], "label": "bad%scontrol"}]}' % char(0x07))

	for i in cases.size():
		_write_malformed_json_fixture_bundle(cases[i])
		var registry := ContentRegistryType.new(MALFORMED_JSON_FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)
		_cleanup_dir(MALFORMED_JSON_FIXTURE_DIR)

		_expect(not registry.is_valid(), "malformed JSON case %d must fail construction: %s" % [i, cases[i]])
		var error := registry.get_error()
		_expect(error.get("code") == ContentRegistryType.ERROR_INVALID_JSON,
			"malformed JSON case %d must be typed as invalid_json, got %s" % [i, error])

## Same otherwise-valid bundle as _write_fixture_bundle(), except jobs.json is
## written verbatim as malformed_jobs_text rather than through _write_json()
## (JSON.stringify() cannot produce malformed JSON, by construction).
func _write_malformed_json_fixture_bundle(malformed_jobs_text: String) -> void:
	var dir := DirAccess.open("user://")
	if not dir.dir_exists(MALFORMED_JSON_FIXTURE_DIR):
		dir.make_dir_recursive(MALFORMED_JSON_FIXTURE_DIR)

	_write_json(MALFORMED_JSON_FIXTURE_DIR + "/manifest.json", {"version": "0.0.1-fixture"})
	_write_json(MALFORMED_JSON_FIXTURE_DIR + "/items.json", {"items": [{"id": "axe", "kind": "tool"}]})
	_write_json(MALFORMED_JSON_FIXTURE_DIR + "/objects.json", {"objects": [
		{"kind": "bed", "passable": true, "move_cost": 3, "is_door": false, "footprint": [1, 1], "rotatable": false, "build_ticks": 40, "max_builders": 1, "build_cost": []},
	]})
	_write_json(MALFORMED_JSON_FIXTURE_DIR + "/needs.json", {"needs": [
		{"kind": "rest", "rate_per_day": 80, "warn": 50, "urgent": 25, "critical": 10, "restore": 100, "source_kind": "bed", "full": 100, "job_priority": 1, "retry_base_ticks": 10, "retry_cap_ticks": 40},
	]})
	_write_json(MALFORMED_JSON_FIXTURE_DIR + "/calendar.json", {"day_length_ticks": 100, "windows": []})
	_write_required_tiles_and_mapgen(MALFORMED_JSON_FIXTURE_DIR)
	var file := FileAccess.open(MALFORMED_JSON_FIXTURE_DIR + "/jobs.json", FileAccess.WRITE)
	file.store_string(malformed_jobs_text)
	file.close()

## Writes a small, otherwise-valid six-file content bundle whose jobs.json
## deliberately names "does_not_exist" as chop's needs_tool -- no item with
## that id is declared in the fixture's items.json.
func _write_fixture_bundle() -> void:
	var dir := DirAccess.open("user://")
	if not dir.dir_exists(FIXTURE_DIR):
		dir.make_dir_recursive(FIXTURE_DIR)

	_write_json(FIXTURE_DIR + "/manifest.json", {"version": "0.0.1-fixture"})
	_write_json(FIXTURE_DIR + "/items.json", {"items": [{"id": "axe", "kind": "tool"}]})
	_write_json(FIXTURE_DIR + "/objects.json", {"objects": [
		{"kind": "bed", "passable": true, "move_cost": 3, "is_door": false, "footprint": [1, 1], "rotatable": false, "build_ticks": 40, "max_builders": 1, "build_cost": []},
	]})
	_write_json(FIXTURE_DIR + "/needs.json", {"needs": [
		{"kind": "rest", "rate_per_day": 80, "warn": 50, "urgent": 25, "critical": 10, "restore": 100, "source_kind": "bed", "full": 100, "job_priority": 1, "retry_base_ticks": 10, "retry_cap_ticks": 40},
	]})
	_write_json(FIXTURE_DIR + "/calendar.json", {"day_length_ticks": 100, "windows": []})
	_write_json(FIXTURE_DIR + "/jobs.json", {"jobs": [
		{"kind": "chop", "labour": "chop", "needs_tool": "does_not_exist", "toils": ["reserve", "go_to", "work", "release_all"]},
	]})
	_write_required_tiles_and_mapgen(FIXTURE_DIR)

## A content kind with no matching COLLECTION_KINDS/DOCUMENT_KINDS entry
## ("widgets") but with a matching schema must still be discovered, loaded
## and validated -- never silently skipped -- per review round 3's finding
## that the constructor previously only ever looked at its hardcoded kind
## list. Proven by making the extra kind's content violate its own schema:
## if the registry ignored it, construction would succeed (every required
## kind here is otherwise valid); requiring it to fail instead proves the
## extra file was actually read and validated.
func _check_extra_content_kind_with_matching_schema_is_not_ignored() -> void:
	_write_extra_kind_fixture_bundle()
	var registry := ContentRegistryType.new(EXTRA_KIND_CONTENT_DIR, EXTRA_KIND_SCHEMA_DIR)
	_cleanup_dir(EXTRA_KIND_CONTENT_DIR)
	_cleanup_dir(EXTRA_KIND_SCHEMA_DIR)

	_expect(not registry.is_valid(),
		"a content kind outside COLLECTION_KINDS/DOCUMENT_KINDS with a matching schema must still be validated, not ignored")
	var error := registry.get_error()
	_expect(error.get("code") == ContentRegistryType.ERROR_SCHEMA_VIOLATION,
		"the extra kind's schema violation must be typed as schema_violation, got %s" % error)
	_expect(String(error.get("file", "")).ends_with("widgets.json"),
		"the extra kind's error must name widgets.json as the offending file, got %s" % error)

## An otherwise-valid six-file bundle (content_dir) paired with a schema_dir
## that is a copy of the six real schemas plus one more, "widgets.schema.json",
## requiring a "count" field of at least 100. content_dir's widgets.json gives
## count the value 1, well below that minimum.
func _write_extra_kind_fixture_bundle() -> void:
	var user_dir := DirAccess.open("user://")
	if not user_dir.dir_exists(EXTRA_KIND_CONTENT_DIR):
		user_dir.make_dir_recursive(EXTRA_KIND_CONTENT_DIR)
	if not user_dir.dir_exists(EXTRA_KIND_SCHEMA_DIR):
		user_dir.make_dir_recursive(EXTRA_KIND_SCHEMA_DIR)

	_write_json(EXTRA_KIND_CONTENT_DIR + "/manifest.json", {"version": "0.0.1-fixture"})
	_write_json(EXTRA_KIND_CONTENT_DIR + "/items.json", {"items": [{"id": "axe", "kind": "tool"}]})
	_write_json(EXTRA_KIND_CONTENT_DIR + "/objects.json", {"objects": [
		{"kind": "bed", "passable": true, "move_cost": 3, "is_door": false, "footprint": [1, 1], "rotatable": false, "build_ticks": 40, "max_builders": 1, "build_cost": []},
	]})
	_write_json(EXTRA_KIND_CONTENT_DIR + "/needs.json", {"needs": [
		{"kind": "rest", "rate_per_day": 80, "warn": 50, "urgent": 25, "critical": 10, "restore": 100, "source_kind": "bed", "full": 100, "job_priority": 1, "retry_base_ticks": 10, "retry_cap_ticks": 40},
	]})
	_write_json(EXTRA_KIND_CONTENT_DIR + "/calendar.json", {"day_length_ticks": 100, "windows": []})
	_write_json(EXTRA_KIND_CONTENT_DIR + "/jobs.json", {"jobs": [
		{"kind": "chop", "labour": "chop", "toils": ["reserve", "go_to", "work", "release_all"]},
	]})
	_write_required_tiles_and_mapgen(EXTRA_KIND_CONTENT_DIR)
	_write_json(EXTRA_KIND_CONTENT_DIR + "/widgets.json", {"count": 1})

	for kind in ["manifest", "items", "objects", "needs", "calendar", "jobs", "tiles", "mapgen", "actors", "factions", "incidents"]:
		_copy_res_file("res://content/schemas/%s.schema.json" % kind, EXTRA_KIND_SCHEMA_DIR + "/%s.schema.json" % kind)
	_write_json(EXTRA_KIND_SCHEMA_DIR + "/widgets.schema.json", {
		"type": "object",
		"required": ["count"],
		"additionalProperties": false,
		"properties": {"count": {"type": "integer", "minimum": 100}},
	})

func _copy_res_file(res_path: String, dest_path: String) -> void:
	var src := FileAccess.open(res_path, FileAccess.READ)
	var text := src.get_as_text()
	src.close()
	var dst := FileAccess.open(dest_path, FileAccess.WRITE)
	dst.store_string(text)
	dst.close()

## tiles/mapgen/actors/factions/incidents are now required kinds
## (COLLECTION_KINDS/DOCUMENT_KINDS); every otherwise-valid fixture bundle
## below needs all five files or construction fails with ERROR_MISSING_FILE
## before it ever reaches the case under test. The two-faction bundle here is
## the smallest one that satisfies _check_references()'s "one relation row
## per other declared faction" completeness check; incidents.json's single
## entry names only ids this same fixture already declares ("colonist",
## "wildlife").
func _write_required_tiles_and_mapgen(dir: String) -> void:
	_write_json(dir + "/tiles.json", {"tiles": [
		{"id": "floor", "passable": true, "move_cost": 1, "diggable": false, "display": {"label": "Floor"}, "move_ticks_per_tile": 4},
	]})
	_write_json(dir + "/mapgen.json", {
		"rock_vein_count": 1, "rock_vein_min_length": 1, "rock_vein_max_length": 1,
		"hazard_count": 0, "hazard_placement_attempts": 1,
		"tree_count": 0, "tree_placement_attempts": 1,
		"water_count": 0, "water_placement_attempts": 1,
		"spawn_area_x": 0, "spawn_area_y": 0, "spawn_area_width": 1, "spawn_area_height": 1,
		"colonist_count": 1,
	})
	_write_json(dir + "/actors.json", {"actors": [
		{"id": "colonist", "components": ["mover"], "tunables": {"mover": {"speed": 1}}},
	]})
	_write_json(dir + "/factions.json", {"factions": [
		{"id": "colony", "relations": {"wildlife": "neutral"}, "rules": {"may_pass_doors": true, "may_reserve_colony_items": true, "may_be_ordered": true}},
		{"id": "wildlife", "relations": {"colony": "hostile"}, "rules": {"may_pass_doors": false, "may_reserve_colony_items": false, "may_be_ordered": false}},
	]})
	_write_json(dir + "/incidents.json", {"incidents": [
		{"id": "test_incident", "faction": "wildlife", "min_day": 1, "weight": 1, "cooldown_days": 1,
			"spawn": {"actor_def": "colonist", "count": 1, "edge": "north", "wait_ticks": 1}},
	]})

func _write_json(path: String, value: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(value))
	file.close()

func _cleanup_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir():
			dir.remove(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path))
