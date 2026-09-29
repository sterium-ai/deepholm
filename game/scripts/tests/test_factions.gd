extends SceneTree

## Covers issue #286 (F3 factions and relations,
## docs/architecture/foundation-for-breadth.md section F3,
## docs/decisions/015-factions-and-relations.md): 1) the real
## game/content/factions.json bundle loads through ContentRegistry with
## exactly the six declared factions (issue #304 added "predators"), only
## colony's rules.may_be_ordered is true, and Relations.relation() correctly
## reads an asymmetric row without assuming symmetry; 2) a small fixture
## bundle written to a user:// temp directory (following
## test_content_registry.gd's fixture-directory pattern) whose actors.json
## names an unknown faction_id fails ContentRegistry construction with the
## typed dangling_reference error, exactly mirroring the existing
## needs.source_kind / jobs.needs_tool dangling-reference checks.

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const RelationsType = preload("res://scripts/core/relations/relations.gd")

const FIXTURE_CONTENT_DIR := "user://test-factions-fixture-content"
const FIXTURE_SCHEMA_DIR := "user://test-factions-fixture-schemas"

const EXPECTED_FACTION_IDS := ["allies", "colony", "predators", "raiders", "traders", "wildlife"]

## One value per malformed JSON type a "relations" row entry could hold
## instead of a string: number, boolean, null, array, object. Each must fail
## construction with a typed dangling_reference error rather than crashing a
## GDScript String() conversion (see content_registry.gd's _check_references()).
const MALFORMED_RELATION_VALUES := [5, true, null, [1, 2], {"nested": true}]

var _failed := false

func _init() -> void:
	_check_real_bundle_has_six_factions_and_ordering_rule()
	_check_relation_is_not_assumed_symmetric()
	_check_fixture_with_unknown_actor_faction_id_fails_construction()
	_check_fixture_with_malformed_relation_value_fails_construction()

	if _failed:
		quit(1)
		return
	print("test_factions: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## The real content bundle must declare exactly the six factions (issue #304
## added "predators"), and only "colony" may be given player orders.
func _check_real_bundle_has_six_factions_and_ordering_rule() -> void:
	var registry := ContentRegistryType.new()
	_expect(registry.is_valid(), "the real content bundle must load validly: %s" % registry.get_error())
	if not registry.is_valid():
		return

	var factions := registry.list("factions")
	_expect(factions.size() == 6, "factions collection must contain exactly six entries, got %d" % factions.size())

	var found_ids: Array = []
	for faction in factions:
		found_ids.append(String(faction.get("id", "")))
	found_ids.sort()
	_expect(found_ids == EXPECTED_FACTION_IDS,
		"factions collection must contain exactly %s, got %s" % [EXPECTED_FACTION_IDS, found_ids])

	for faction_id in EXPECTED_FACTION_IDS:
		var entry := registry.get_entry("factions", faction_id)
		var rules: Dictionary = entry.get("rules", {})
		var may_be_ordered := bool(rules.get("may_be_ordered", false))
		var expected: bool = faction_id == "colony"
		_expect(may_be_ordered == expected,
			"faction '%s' rules.may_be_ordered must be %s, got %s" % [faction_id, expected, may_be_ordered])

## Relations.relation() must read the calling faction's own row rather than
## assuming a symmetric matrix: content/factions.json declares colony's
## relation to wildlife as "neutral" but wildlife's relation to colony as
## "hostile" (wolves attack colonists on sight; colonists do not treat
## wildlife as hostile by default).
func _check_relation_is_not_assumed_symmetric() -> void:
	var registry := ContentRegistryType.new()
	if not registry.is_valid():
		_fail("the real content bundle must load validly for the relation-asymmetry check")
		return

	var relations := RelationsType.new(registry)
	var colony_to_wildlife := relations.relation("colony", "wildlife")
	var wildlife_to_colony := relations.relation("wildlife", "colony")
	_expect(colony_to_wildlife == "neutral",
		"colony's relation to wildlife must be 'neutral', got '%s'" % colony_to_wildlife)
	_expect(wildlife_to_colony == "hostile",
		"wildlife's relation to colony must be 'hostile', got '%s'" % wildlife_to_colony)
	_expect(colony_to_wildlife != wildlife_to_colony,
		"relation() must not assume a symmetric matrix: colony->wildlife and wildlife->colony must differ")

	_expect(relations.relation("colony", "colony") == "friendly",
		"a faction relating to itself must always be 'friendly'")

## A fixture bundle whose actors.json names "does_not_exist" as an actor's
## faction_id -- no faction with that id is declared in the fixture's
## factions.json -- must fail construction with a typed dangling_reference
## error, never a silently-applied default. The fixture uses its own schema
## directory (a copy of the real schemas, with actors.schema.json swapped for
## a variant that additionally permits the optional faction_id field this
## task's registry check reads) so the real, out-of-scope
## content/schemas/actors.schema.json is never touched.
func _check_fixture_with_unknown_actor_faction_id_fails_construction() -> void:
	_write_fixture_bundle()
	var registry := ContentRegistryType.new(FIXTURE_CONTENT_DIR, FIXTURE_SCHEMA_DIR)
	_cleanup_dir(FIXTURE_CONTENT_DIR)
	_cleanup_dir(FIXTURE_SCHEMA_DIR)

	_expect(not registry.is_valid(), "a fixture bundle with an unknown actor faction_id must fail construction")
	var error := registry.get_error()
	_expect(error.get("code") == ContentRegistryType.ERROR_DANGLING_REFERENCE,
		"the fixture's error code must be typed as dangling_reference, got %s" % error)
	_expect(String(error.get("file", "")).ends_with("actors.json"),
		"the fixture's error must name actors.json as the offending file, got %s" % error)
	_expect(registry.list("factions").is_empty(), "an invalid registry must expose no factions, never a partial default")

## Each malformed value (see MALFORMED_RELATION_VALUES) must fail construction
## with the same typed dangling_reference error the unknown-id case above
## uses, and must never leak a partially-populated registry.
func _check_fixture_with_malformed_relation_value_fails_construction() -> void:
	for malformed_value in MALFORMED_RELATION_VALUES:
		_write_fixture_bundle_with_relation_value(malformed_value)
		var registry := ContentRegistryType.new(FIXTURE_CONTENT_DIR, FIXTURE_SCHEMA_DIR)
		_cleanup_dir(FIXTURE_CONTENT_DIR)
		_cleanup_dir(FIXTURE_SCHEMA_DIR)

		_expect(not registry.is_valid(),
			"a fixture bundle with a malformed relation value %s must fail construction" % [malformed_value])
		var error := registry.get_error()
		_expect(error.get("code") == ContentRegistryType.ERROR_DANGLING_REFERENCE,
			"the malformed-relation-value error code must be typed as dangling_reference, got %s for value %s" % [error, malformed_value])
		_expect(String(error.get("file", "")).ends_with("factions.json"),
			"the malformed-relation-value error must name factions.json as the offending file, got %s for value %s" % [error, malformed_value])
		_expect(registry.list("factions").is_empty(),
			"an invalid registry must expose no factions, never a partial default, for malformed relation value %s" % [malformed_value])

func _write_fixture_bundle() -> void:
	_ensure_fixture_dirs()
	_write_common_fixture_content()
	_write_json(FIXTURE_CONTENT_DIR + "/factions.json", {"factions": [
		{"id": "colony", "relations": {"wildlife": "neutral"}, "rules": {"may_pass_doors": true, "may_reserve_colony_items": true, "may_be_ordered": true}},
		{"id": "wildlife", "relations": {"colony": "hostile"}, "rules": {"may_pass_doors": false, "may_reserve_colony_items": false, "may_be_ordered": false}},
	]})
	## "does_not_exist" is named by no entry in factions.json above -- the
	## deliberate dangling reference this test proves ContentRegistry catches.
	_write_json(FIXTURE_CONTENT_DIR + "/actors.json", {"actors": [
		{"id": "colonist", "components": ["mover"], "tunables": {"mover": {"speed": 1}}, "faction_id": "does_not_exist"},
	]})
	_write_fixture_schemas()

## Same bundle shape as _write_fixture_bundle(), but factions.json's
## colony->wildlife relation is set to relation_value (a malformed, non-string
## JSON type) and actors.json declares no faction_id at all, so the only
## possible construction failure is the malformed relation value itself, not
## the unrelated unknown-actor-faction_id case _write_fixture_bundle() covers.
func _write_fixture_bundle_with_relation_value(relation_value) -> void:
	_ensure_fixture_dirs()
	_write_common_fixture_content()
	_write_json(FIXTURE_CONTENT_DIR + "/factions.json", {"factions": [
		{"id": "colony", "relations": {"wildlife": relation_value}, "rules": {"may_pass_doors": true, "may_reserve_colony_items": true, "may_be_ordered": true}},
		{"id": "wildlife", "relations": {"colony": "hostile"}, "rules": {"may_pass_doors": false, "may_reserve_colony_items": false, "may_be_ordered": false}},
	]})
	_write_json(FIXTURE_CONTENT_DIR + "/actors.json", {"actors": [
		{"id": "colonist", "components": ["mover"], "tunables": {"mover": {"speed": 1}}},
	]})
	_write_fixture_schemas()

func _ensure_fixture_dirs() -> void:
	var user_dir := DirAccess.open("user://")
	if not user_dir.dir_exists(FIXTURE_CONTENT_DIR):
		user_dir.make_dir_recursive(FIXTURE_CONTENT_DIR)
	if not user_dir.dir_exists(FIXTURE_SCHEMA_DIR):
		user_dir.make_dir_recursive(FIXTURE_SCHEMA_DIR)

## The kinds a valid registry always requires, other than factions.json and
## actors.json, which differ per scenario and are written by each caller.
func _write_common_fixture_content() -> void:
	_write_json(FIXTURE_CONTENT_DIR + "/manifest.json", {"version": "0.0.1-fixture"})
	_write_json(FIXTURE_CONTENT_DIR + "/items.json", {"items": [{"id": "axe", "kind": "tool"}]})
	_write_json(FIXTURE_CONTENT_DIR + "/objects.json", {"objects": [
		{"kind": "bed", "passable": true, "move_cost": 3, "is_door": false, "footprint": [1, 1], "rotatable": false, "build_ticks": 40, "max_builders": 1, "build_cost": []},
	]})
	_write_json(FIXTURE_CONTENT_DIR + "/needs.json", {"needs": [
		{"kind": "rest", "rate_per_day": 80, "warn": 50, "urgent": 25, "critical": 10, "restore": 100, "source_kind": "bed", "full": 100, "job_priority": 1, "retry_base_ticks": 10, "retry_cap_ticks": 40},
	]})
	_write_json(FIXTURE_CONTENT_DIR + "/calendar.json", {"day_length_ticks": 100, "windows": []})
	_write_json(FIXTURE_CONTENT_DIR + "/jobs.json", {"jobs": [
		{"kind": "chop", "labour": "chop", "toils": ["reserve", "go_to", "work", "release_all"]},
	]})
	_write_json(FIXTURE_CONTENT_DIR + "/tiles.json", {"tiles": [
		{"id": "floor", "passable": true, "move_cost": 1, "diggable": false, "display": {"label": "Floor"}, "move_ticks_per_tile": 4},
	]})
	_write_json(FIXTURE_CONTENT_DIR + "/mapgen.json", {
		"rock_vein_count": 1, "rock_vein_min_length": 1, "rock_vein_max_length": 1,
		"hazard_count": 0, "hazard_placement_attempts": 1,
		"tree_count": 0, "tree_placement_attempts": 1,
		"water_count": 0, "water_placement_attempts": 1,
		"spawn_area_x": 0, "spawn_area_y": 0, "spawn_area_width": 1, "spawn_area_height": 1,
		"colonist_count": 1,
	})
	# "incidents" is now a required kind too; both callers' actors.json always
	# declares id "colonist" and factions.json always declares "wildlife", so
	# referencing them here never introduces a second, unrelated
	# dangling-reference failure ahead of whichever case is under test.
	_write_json(FIXTURE_CONTENT_DIR + "/incidents.json", {"incidents": [
		{"id": "test_incident", "faction": "wildlife", "min_day": 1, "weight": 1, "cooldown_days": 1,
			"spawn": {"actor_def": "colonist", "count": 1, "edge": "north", "wait_ticks": 1}},
	]})

func _write_fixture_schemas() -> void:
	for kind in ["manifest", "items", "objects", "needs", "calendar", "jobs", "tiles", "mapgen", "factions", "incidents"]:
		_copy_res_file("res://content/schemas/%s.schema.json" % kind, FIXTURE_SCHEMA_DIR + "/%s.schema.json" % kind)
	_write_actors_schema_with_optional_faction_id(FIXTURE_SCHEMA_DIR + "/actors.schema.json")

## A copy of the real actors.schema.json's shape, extended with an optional
## "faction_id" string property -- the field content/schemas/actors.schema.json
## itself does not declare yet (adding it there for every real actor
## definition is a later task's scope; see docs/decisions/
## 015-factions-and-relations.md). Kept minimal (no per-component tunables
## shape) since this fixture's only job is to exercise the faction_id
## dangling-reference check, not re-prove actors.schema.json's own rules.
func _write_actors_schema_with_optional_faction_id(path: String) -> void:
	_write_json(path, {
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"type": "object",
		"required": ["actors"],
		"additionalProperties": false,
		"properties": {
			"actors": {
				"type": "array",
				"minItems": 1,
				"items": {
					"type": "object",
					"required": ["id", "components", "tunables"],
					"additionalProperties": false,
					"properties": {
						"id": {"type": "string", "minLength": 1},
						"faction_id": {"type": "string", "minLength": 1},
						"components": {"type": "array", "minItems": 1, "items": {"type": "string", "minLength": 1}},
						"tunables": {"type": "object"},
					},
				},
			},
		},
	})

func _copy_res_file(res_path: String, dest_path: String) -> void:
	var src := FileAccess.open(res_path, FileAccess.READ)
	var text := src.get_as_text()
	src.close()
	var dst := FileAccess.open(dest_path, FileAccess.WRITE)
	dst.store_string(text)
	dst.close()

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
