extends SceneTree

## Covers content packs (A13, ADR 010 amendment): ContentRegistry built from
## an ordered list of roots (the base res://content/ bundle, then pack roots
## written to user:// at runtime). 1) the real bundle loads unchanged with no
## packs, and boot.gd's session registry is one shared instance; 2) a pack
## that adds an item and overrides a tile loads headless, through a real
## WorldState; 3) roots apply in order; 4) a duplicate id, in the base or in a
## pack, fails with schema_violation, and every other pack rule fails typed;
## 5) the validator's enum is enforced; 6) cross-file checks run on the merged
## bundle.

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")
const BootType = preload("res://scripts/boot.gd")

const BASE := ContentRegistryType.DEFAULT_CONTENT_DIR
const SCHEMAS := ContentRegistryType.DEFAULT_SCHEMA_DIR
const PACK_A_DIR := "user://test-content-packs-a"
const PACK_B_DIR := "user://test-content-packs-b"
const BASE_COPY_DIR := "user://test-content-packs-base-copy"
const MISSING_PACK_DIR := "user://test-content-packs-does-not-exist"

const SOIL_OVERRIDE := {"id": "soil", "passable": true, "move_cost": 3, "diggable": true,
	"display": {"label": "Soil"}, "move_ticks_per_tile": 4}

var _failed := false

func _init() -> void:
	_check_real_bundle_loads_unchanged()
	_check_session_registry_is_shared()
	_check_pack_adds_item_and_overrides_tile_headless()
	_check_roots_apply_in_order()
	_check_duplicate_id_in_base_fails()
	_check_duplicate_ids_in_pack_fail()
	_check_override_of_unknown_id_fails()
	_check_pack_shape_rules_fail_typed()
	_check_enum_is_enforced()
	_check_cross_references_run_on_merged_bundle()

	if _failed:
		quit(1)
		return
	print("test_content_packs: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _check_real_bundle_loads_unchanged() -> void:
	var plain := ContentRegistryType.new()
	var rooted := ContentRegistryType.new(BASE, SCHEMAS, [] as Array[String])
	_expect(rooted.is_valid(), "the real bundle must load with an empty pack list: %s" % rooted.get_error())
	_expect(rooted.packs().is_empty() and rooted.packs().is_read_only(), "no packs must give a frozen empty packs()")
	_expect(rooted.version() == plain.version(), "the pack-less registry must keep the manifest version")
	for kind in ContentRegistryType.COLLECTION_KINDS:
		_expect(rooted.list(kind) == plain.list(kind), "kind '%s' must load unchanged with no packs" % kind)
	for kind in ContentRegistryType.DOCUMENT_KINDS:
		_expect(rooted.document(kind) == plain.document(kind), "document '%s' must load unchanged with no packs" % kind)
	var injected := WorldStateType.new(42, 10, 48, 48, false, rooted)
	var default_world := WorldStateType.new(42, 10, 48, 48)
	_expect(injected.state_hash() == default_world.state_hash(),
		"a WorldState given the session registry must hash like one that builds its own")

func _check_session_registry_is_shared() -> void:
	var first := BootType.session_content()
	_expect(first.is_valid(), "boot's session registry must load: %s" % first.get_error())
	_expect(BootType.session_content() == first, "boot must build one ContentRegistry per session, not one per call")
	_expect(first.packs().size() == BootType.CONTENT_PACK_ROOTS.size(), "the session registry must apply CONTENT_PACK_ROOTS")

func _check_pack_adds_item_and_overrides_tile_headless() -> void:
	_write_pack(PACK_A_DIR, "test_pack", {
		"items": {"items": [{"id": "pack_hammer", "kind": "tool"}]},
		"tiles": {"overrides": [SOIL_OVERRIDE]},
	})
	var registry := ContentRegistryType.new(BASE, SCHEMAS, [PACK_A_DIR] as Array[String])
	_cleanup_dir(PACK_A_DIR)
	_expect(registry.is_valid(), "a pack adding an item and overriding a tile must load: %s" % registry.get_error())
	if not registry.is_valid():
		return
	_expect(registry.packs() == [{"id": "test_pack", "version": "1"}], "packs() must list the pack, got %s" % [registry.packs()])
	_expect(registry.get_entry("items", "pack_hammer").get("kind") == "tool", "the pack's new item must be listed")
	_expect(not registry.get_entry("items", "axe").is_empty(), "base items must survive a pack append")
	_expect(registry.get_entry("tiles", "soil").get("move_cost") == 3, "the pack must override soil's move_cost")
	_expect(registry.list("tiles").size() == ContentRegistryType.new().list("tiles").size(), "an override must not add a tile")

	var world := WorldStateType.new(42, 10, 48, 48, false, registry)
	_expect(world.is_tool_kind("pack_hammer"), "the world must see the pack's item definition")
	var soil_cost := -1
	for y in world.get_map_height():
		for x in world.get_map_width():
			if soil_cost == -1 and world.get_tile(x, y) == ContentRegistryType.TILE_SOIL and world.get_object(x, y).is_empty():
				soil_cost = int(world.passability(x, y)["cost"])
	_expect(soil_cost == 3, "the world must route over soil at the pack's move_cost 3, got %d" % soil_cost)
	world.tick()
	_expect(world.get_tick() == 1, "a world on pack content must tick headless")

func _check_roots_apply_in_order() -> void:
	_write_pack(PACK_A_DIR, "pack_a", {"items": {"items": [{"id": "pack_gem", "kind": "material"}]}})
	_write_pack(PACK_B_DIR, "pack_b", {"items": {"overrides": [{"id": "pack_gem", "kind": "valuable"}]}})
	var forward := ContentRegistryType.new(BASE, SCHEMAS, [PACK_A_DIR, PACK_B_DIR] as Array[String])
	var reversed := ContentRegistryType.new(BASE, SCHEMAS, [PACK_B_DIR, PACK_A_DIR] as Array[String])
	_cleanup_dir(PACK_A_DIR)
	_cleanup_dir(PACK_B_DIR)
	_expect(forward.is_valid(), "a later pack may override an earlier pack's entry: %s" % forward.get_error())
	_expect(forward.get_entry("items", "pack_gem").get("kind") == "valuable", "the later root must win")
	_expect(forward.packs().map(func(p): return p["id"]) == ["pack_a", "pack_b"], "packs() must keep load order")
	_expect_error(reversed, ContentRegistryType.ERROR_DANGLING_REFERENCE, "items.json",
		"an override listed before the pack that appends its id")

func _check_duplicate_id_in_base_fails() -> void:
	_copy_base_bundle(BASE_COPY_DIR)
	var items_path := BASE_COPY_DIR + "/items.json"
	var text := FileAccess.get_file_as_string(items_path)
	_expect(text.contains('{"id": "axe", "kind": "tool"},'), "fixture: items.json must declare axe as expected")
	_write_text(items_path, text.replace('{"id": "axe", "kind": "tool"},', '{"id": "axe", "kind": "tool"}, {"id": "axe", "kind": "material"},'))
	var registry := ContentRegistryType.new(BASE_COPY_DIR, SCHEMAS)
	_cleanup_dir(BASE_COPY_DIR)
	_expect_error(registry, ContentRegistryType.ERROR_SCHEMA_VIOLATION, "items.json", "a base items.json naming 'axe' twice")

func _check_duplicate_ids_in_pack_fail() -> void:
	var cases := {
		"two new entries": {"items": [{"id": "pack_gem", "kind": "material"}, {"id": "pack_gem", "kind": "valuable"}]},
		"two overrides": {"overrides": [{"id": "axe", "kind": "tool"}, {"id": "axe", "kind": "tool"}]},
		"new and override": {"items": [{"id": "pack_gem", "kind": "material"}], "overrides": [{"id": "pack_gem", "kind": "tool"}]},
		"new entry reusing a base id": {"items": [{"id": "axe", "kind": "tool"}]},
	}
	for label in cases:
		_write_pack(PACK_A_DIR, "pack_a", {"items": cases[label]})
		var registry := ContentRegistryType.new(BASE, SCHEMAS, [PACK_A_DIR] as Array[String])
		_cleanup_dir(PACK_A_DIR)
		_expect_error(registry, ContentRegistryType.ERROR_SCHEMA_VIOLATION, "items.json", "a pack with a duplicate id (%s)" % label)

func _check_override_of_unknown_id_fails() -> void:
	_write_pack(PACK_A_DIR, "pack_a", {"items": {"overrides": [{"id": "pack_unknown", "kind": "tool"}]}})
	var registry := ContentRegistryType.new(BASE, SCHEMAS, [PACK_A_DIR] as Array[String])
	_cleanup_dir(PACK_A_DIR)
	_expect_error(registry, ContentRegistryType.ERROR_DANGLING_REFERENCE, "items.json", "an override of an unknown id")

func _check_pack_shape_rules_fail_typed() -> void:
	var missing := ContentRegistryType.new(BASE, SCHEMAS, [MISSING_PACK_DIR] as Array[String])
	_expect_error(missing, ContentRegistryType.ERROR_MISSING_FILE, "pack.json", "a pack root that does not exist")

	_write_pack(PACK_A_DIR, "pack_a", {})
	_write_pack(PACK_B_DIR, "pack_a", {})
	var twice := ContentRegistryType.new(BASE, SCHEMAS, [PACK_A_DIR, PACK_B_DIR] as Array[String])
	_cleanup_dir(PACK_B_DIR)
	_expect_error(twice, ContentRegistryType.ERROR_SCHEMA_VIOLATION, "pack.json", "two roots with the same pack id")

	_write_json(PACK_A_DIR + "/pack.json", {"id": "pack_a"})
	var no_version := ContentRegistryType.new(BASE, SCHEMAS, [PACK_A_DIR] as Array[String])
	_cleanup_dir(PACK_A_DIR)
	_expect_error(no_version, ContentRegistryType.ERROR_SCHEMA_VIOLATION, "pack.json", "a pack.json without a version")

	var bad_files := {
		"mapgen": {"colonist_count": 3},
		"widgets": {"widgets": []},
		"items": {"items": [{"id": "pack_gem"}]},
	}
	for kind in bad_files:
		_write_pack(PACK_A_DIR, "pack_a", {kind: bad_files[kind]})
		var registry := ContentRegistryType.new(BASE, SCHEMAS, [PACK_A_DIR] as Array[String])
		_cleanup_dir(PACK_A_DIR)
		_expect_error(registry, ContentRegistryType.ERROR_SCHEMA_VIOLATION, "%s.json" % kind, "a pack %s.json %s" % [kind, bad_files[kind]])

	_write_pack(PACK_A_DIR, "pack_a", {"items": {"items": [], "remove": ["axe"]}})
	var extra_field := ContentRegistryType.new(BASE, SCHEMAS, [PACK_A_DIR] as Array[String])
	_cleanup_dir(PACK_A_DIR)
	_expect_error(extra_field, ContentRegistryType.ERROR_SCHEMA_VIOLATION, "items.json", "a pack file with a field besides its list and overrides")

## actors.schema.json declares a closed enum on components; before A13 the
## validator ignored enum and only _check_references() caught a stranger.
func _check_enum_is_enforced() -> void:
	var colonist: Dictionary = ContentRegistryType.new().get_entry("actors", "colonist").duplicate(true)
	var components: Array = colonist["components"]
	components.append("flight")
	_write_pack(PACK_A_DIR, "pack_a", {"actors": {"overrides": [colonist]}})
	var registry := ContentRegistryType.new(BASE, SCHEMAS, [PACK_A_DIR] as Array[String])
	_cleanup_dir(PACK_A_DIR)
	_expect_error(registry, ContentRegistryType.ERROR_SCHEMA_VIOLATION, "actors.json", "a component outside the schema enum")
	_expect(String(registry.get_error().get("message", "")).contains("is not one of"),
		"the enum failure must say the value is not one of the allowed values, got %s" % registry.get_error())

## Overriding the axe into a material leaves jobs.json's needs_tool "axe"
## pointing at a non-tool: caught by the same cross-file check as the base.
func _check_cross_references_run_on_merged_bundle() -> void:
	_write_pack(PACK_A_DIR, "pack_a", {"items": {"overrides": [{"id": "axe", "kind": "material"}]}})
	var registry := ContentRegistryType.new(BASE, SCHEMAS, [PACK_A_DIR] as Array[String])
	_cleanup_dir(PACK_A_DIR)
	_expect_error(registry, ContentRegistryType.ERROR_DANGLING_REFERENCE, "jobs.json", "a pack breaking a base cross-reference")

func _expect_error(registry: ContentRegistryType, code: String, file_suffix: String, what: String) -> void:
	_expect(not registry.is_valid(), "%s must fail construction" % what)
	var error := registry.get_error()
	_expect(error.get("code") == code, "%s must fail with %s, got %s" % [what, code, error])
	_expect(String(error.get("file", "")).ends_with(file_suffix), "%s must name %s, got %s" % [what, file_suffix, error])
	_expect(registry.list("items").is_empty(), "%s must expose no partial bundle" % what)

## files: kind -> whole pack file Dictionary, written next to pack.json.
func _write_pack(dir: String, pack_id: String, files: Dictionary) -> void:
	_cleanup_dir(dir)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	_write_json(dir + "/pack.json", {"id": pack_id, "version": "1"})
	for kind in files:
		_write_json("%s/%s.json" % [dir, kind], files[kind])

func _copy_base_bundle(dir: String) -> void:
	_cleanup_dir(dir)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	for file_name in DirAccess.get_files_at(BASE):
		if file_name.ends_with(".json"):
			_write_text("%s/%s" % [dir, file_name], FileAccess.get_file_as_string(BASE + file_name))

func _write_json(path: String, value: Dictionary) -> void:
	_write_text(path, JSON.stringify(value))

func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
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
