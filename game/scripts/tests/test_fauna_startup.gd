extends SceneTree

## F6b-1 review fix (ADR 070 §1): species.json or mapgen.animal_counts that FaunaSpecies rejects is a
## fatal, typed startup error on the real WorldState path, not a logged error and an animal-free
## world. WorldState._fail_startup() kills the process, so each case runs this same script again
## as a child ("--fauna-startup-probe <content dir>") on a tampered copy of res://content/ and the
## parent checks the child never got past WorldState.new() and printed the typed error.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const FaunaSystemType = preload("res://scripts/core/fauna/fauna_system.gd")
const PROBE_FLAG := "--fauna-startup-probe"
const SURVIVED := "FAUNA_STARTUP_PROBE_SURVIVED"
const CONTENT_DIR := "user://test-fauna-startup-content/"
const COUNTS := {"grasshopper": 12, "bird": 3, "rabbit": 6, "deer": 3, "fox": 1, "wolf": 1}

var _failed := false

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var at := args.find(PROBE_FLAG)
	if at >= 0 and at + 1 < args.size():
		_probe(args[at + 1])
		return
	_check_valid_copy_starts()
	_check_unknown_prey_is_fatal()
	_check_unknown_count_species_is_fatal()
	_check_world_seeds_mapgen_counts()
	_remove_content_copy()
	if _failed:
		quit(1)
		return
	print("test_fauna_startup: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## Child: the real startup path on `content_dir`. Reaching the print means startup did not abort.
func _probe(content_dir: String) -> void:
	var content := ContentRegistryType.new(content_dir)
	if not content.is_valid():
		print("probe: ContentRegistry rejected the copy: %s" % [content.get_error()])
		quit(3)
		return
	var world := WorldStateType.new(1, 10, 48, 48, false, content)
	print("%s animals=%d" % [SURVIVED, world._fauna.get_animals().size()])
	quit(0)

func _check_valid_copy_starts() -> void:
	_write_content_copy("", "", "")
	var output := _run_probe()
	_expect(output.contains(SURVIVED), "an untouched content copy must start: %s" % output)

func _check_unknown_prey_is_fatal() -> void:
	_write_content_copy("species", "\"prey\": [\"rabbit\", \"deer\"]", "\"prey\": [\"dragon\"]")
	_expect_fatal(_run_probe(), "unknown prey 'dragon'")

func _check_unknown_count_species_is_fatal() -> void:
	_write_content_copy("mapgen", "{", "{\"animal_counts\": {\"dragon\": 2},")
	_expect_fatal(_run_probe(), "unknown species 'dragon'")

## Review fix (item 3): mapgen.animal_counts seeds animals through WorldState.new() itself, from the
## world seed. Shipped mapgen keeps no counts (ADR 070 §6, pending owner decision 3), so the counts
## go in a content copy; valid content does not abort, so this runs in-process.
func _check_world_seeds_mapgen_counts() -> void:
	_write_content_copy("mapgen", "{", "{\"animal_counts\": %s," % JSON.stringify(COUNTS))
	var content := ContentRegistryType.new(CONTENT_DIR)
	_expect(content.is_valid(), "the counted content copy must load: %s" % [content.get_error()])
	var world := WorldStateType.new(424242, 10, 48, 48, false, content)
	var clearing := world.get_spawn_clearing()
	for id: String in COUNTS.keys():
		_expect(world._fauna.count_of(id) == COUNTS[id], "WorldState must seed %d %s (got %d)" % [COUNTS[id], id, world._fauna.count_of(id)])
	for animal: Dictionary in world._fauna.get_animals():
		_expect(int(animal["z"]) == TileGrid.SURFACE, "seeded animals live on the surface")
		_expect(not FaunaSystemType._in_clearing(TileGrid.tile_of(animal), clearing), "no animal is seeded in the clearing")
	var again := WorldStateType.new(424242, 10, 48, 48, false, content)
	_expect(again._fauna.get_animals() == world._fauna.get_animals(), "the same seed must seed the same animals")
	_expect(again.state_hash() == world.state_hash(), "the same seed must give the same state_hash()")
	var other := WorldStateType.new(424243, 10, 48, 48, false, content)
	_expect(other._fauna.get_animals() != world._fauna.get_animals(), "another seed must seed them elsewhere")
	_expect(world.state_hash() != WorldStateType.new(424242, 10, 48, 48).state_hash(), "seeded animals must be in state_hash()")
	_expect((world.get_view_snapshot()["animals"] as Array).size() == world._fauna.get_animals().size(), "the view must see them")

func _expect_fatal(output: String, detail: String) -> void:
	_expect(not output.contains(SURVIVED), "bad fauna content must abort WorldState startup: %s" % output)
	_expect(not output.contains("ContentRegistry rejected"), "the case must reach WorldState, not the registry: %s" % output)
	_expect(output.contains("fatal fauna content error (%s)" % FaunaSystemType.ERROR_INVALID_SPECIES_CONTENT),
		"the abort must carry the typed fauna error: %s" % output)
	_expect(output.contains(detail), "the abort must name the bad entry '%s': %s" % [detail, output])

## Copies every res://content/*.json into CONTENT_DIR byte for byte, except that in `kind`.json the
## first `find` becomes `replace`. A text edit, not a JSON re-encode, so integers stay integers for
## the schema check. Schemas stay at res://content/schemas/.
func _write_content_copy(kind: String, find: String, replace: String) -> void:
	_remove_content_copy()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CONTENT_DIR))
	for file_name: String in DirAccess.get_files_at("res://content/"):
		if not file_name.ends_with(".json"):
			continue
		var text := FileAccess.get_file_as_string("res://content/" + file_name)
		if file_name == kind + ".json":
			_expect(text.contains(find), "the %s tamper target must exist: %s" % [file_name, find])
			var at := text.find(find)
			text = text.substr(0, at) + replace + text.substr(at + find.length())
		var file := FileAccess.open(CONTENT_DIR + file_name, FileAccess.WRITE)
		file.store_string(text)
		file.close()

func _remove_content_copy() -> void:
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(CONTENT_DIR)):
		return
	for file_name: String in DirAccess.get_files_at(CONTENT_DIR):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CONTENT_DIR + file_name))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CONTENT_DIR))

func _run_probe() -> String:
	var output: Array = []
	OS.execute(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script",
		"res://scripts/tests/test_fauna_startup.gd", "--", PROBE_FLAG, CONTENT_DIR], output, true)
	return "\n".join(output)
