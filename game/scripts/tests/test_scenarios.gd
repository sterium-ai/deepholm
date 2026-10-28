extends SceneTree

## Covers scenarios as content (A16, ADR 052): 1) the base bundle ships the "new_game" and
## "debug" scenarios; 2) both build headless with a deterministic state_hash(), the same
## after the same ticks, through ScenarioBuilder and through boot.gd/DebugScenario's entry
## points; 3) "when": "scenario_seed" steps run only for the scenario's own seed; 4) a
## scenario a pack adds builds, with its own size, seed and objects; 5) every scenario rule
## the registry enforces fails typed; 6) an unknown scenario or a missing seed builds
## nothing; 7) the New Game dialog lists the scenarios and boot builds the one picked.
## The byte-identity of the default New Game against main is shown by
## docs/orca/handoffs/A16-scenario_dump.gd, not here (there is no older builder to compare).

const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const ScenarioBuilderType = preload("res://scripts/core/world/scenario_builder.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")
const BootType = preload("res://scripts/boot.gd")
const DebugScenarioType = preload("res://scripts/viewer/debug_scenario.gd")
const NewGameDialogType = preload("res://scripts/viewer/new_game_dialog.gd")

const BASE := ContentRegistryType.DEFAULT_CONTENT_DIR
const SCHEMAS := ContentRegistryType.DEFAULT_SCHEMA_DIR
const PACK_DIR := "user://test-scenarios-pack"
const TRACE_TICKS := 40
const NEW_GAME_SEED := 42

var _failed := false
var _content := ContentRegistryType.new()

func _init() -> void:
	_check_base_bundle_ships_both_scenarios()
	_check_new_game_is_deterministic()
	_check_debug_is_deterministic()
	_check_seed_gated_steps_run_only_for_the_scenario_seed()
	_check_pack_scenario_builds()
	_check_registry_rejects_bad_scenarios()
	_check_unknown_scenario_or_missing_seed_builds_nothing()
	_check_dialog_picks_the_scenario_boot_builds()

	if _failed:
		quit(1)
		return
	print("test_scenarios: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _check_base_bundle_ships_both_scenarios() -> void:
	_expect(_content.is_valid(), "the base bundle must load: %s" % _content.get_error())
	var ids: Array = []
	for scenario: Dictionary in _content.list("scenarios"):
		ids.append(scenario["id"])
	_expect(ids == ["debug", "new_game"], "the base bundle must ship exactly debug and new_game, got %s" % [ids])
	_expect(_content.get_entry("scenarios", "debug").is_read_only(), "scenario entries must be frozen")

## Two builds of the same scenario hash alike at tick 0 and after TRACE_TICKS ticks, and the
## builder matches boot.gd's New Game entry point.
func _check_new_game_is_deterministic() -> void:
	var options := {"seed": NEW_GAME_SEED}
	var first := ScenarioBuilderType.build(_content, "new_game", options)
	var second := ScenarioBuilderType.build(_content, "new_game", options)
	var boot_world := BootType.build_default_world(NEW_GAME_SEED, 10, _content)
	_expect(first.get_map_width() == 256 and first.get_map_height() == 256,
		"new_game must use mapgen.json's default size, got %dx%d" % [first.get_map_width(), first.get_map_height()])
	_expect(not first.get_tool_items().is_empty(), "new_game's needed_tools step must place the starting tools")
	var beds := first.get_objects().filter(func(o: Dictionary) -> bool: return o["kind"] == "bed")
	_expect(beds.size() == first.get_colonists().size(), "new_game must place one bed per colonist, got %d" % beds.size())
	_expect_same_run([first, second, boot_world], "new_game")
	var other := ScenarioBuilderType.build(_content, "new_game", {"seed": NEW_GAME_SEED + 1})
	_expect(other.state_hash() != BootType.build_default_world(NEW_GAME_SEED, 10, _content).state_hash(),
		"a different seed must build a different new game")

func _check_debug_is_deterministic() -> void:
	var first := ScenarioBuilderType.build(_content, "debug")
	var second := ScenarioBuilderType.build(_content, "debug")
	var via_viewer := DebugScenarioType.build()
	_expect(first.get_map_width() == 48 and first.get_map_height() == 48, "debug must use its own 48x48 map")
	_expect(first.get_seed() == DebugScenarioType.scenario_seed(), "debug must use its own seed")
	_expect(first.get_tick() > 0, "debug's till_plot step must have run real ticks")
	var kinds: Dictionary = {}
	for placed: Dictionary in first.get_objects():
		kinds[placed["kind"]] = true
	for kind in ["wooden_wall", "door", "chair", "table", "berry_bush", "bed"]:
		_expect(kinds.has(kind), "debug's object_rows step must place a %s" % kind)
	# The scenario's own incidents_enabled (true) against DebugScenario's tests default (off).
	_expect(first.state_hash() != via_viewer.state_hash(), "options.incidents_enabled must override the entry")
	_expect_same_run([first, second, DebugScenarioType.build(null, null, true)], "debug")
	var off := DebugScenarioType.build()
	var off_again := ScenarioBuilderType.build(_content, "debug", {"incidents_enabled": false})
	_expect_same_run([off, off_again], "debug with incidents off")
	_expect(first.state_hash() != BootType.build_default_world(NEW_GAME_SEED, 10, _content).state_hash(),
		"the two scenarios must build different worlds")

func _check_seed_gated_steps_run_only_for_the_scenario_seed() -> void:
	var own := DebugScenarioType.build()
	var other := DebugScenarioType.build(1201)
	_expect(_count_tiles(own, WorldStateType.TILE_PLOWED_SOIL) == 1, "the scenario seed must till one starting plot")
	_expect(_seed_stock(own) == DebugScenarioType.starting_seed_count(), "the scenario seed must drop the seed stock")
	_expect(other.get_tick() == 0, "another seed must skip till_plot and stay at tick 0, got tick %d" % other.get_tick())
	_expect(_count_tiles(other, WorldStateType.TILE_PLOWED_SOIL) == 0, "another seed must not till")
	_expect(_seed_stock(other) == 0, "another seed must not drop the seed stock")
	_expect(not other.get_jobs(["dig"]).is_empty(), "another seed must still run the ungated dig_orders step")

## A pack adds a 32x32 scenario with a fixed seed, its own tick rate and a row of chairs.
func _check_pack_scenario_builds() -> void:
	_write_pack({"scenarios": {"scenarios": [{
		"id": "pack_camp", "label": "Pack camp", "seed": 77, "map": {"width": 32, "height": 32},
		"tick_rate": 5, "incidents_enabled": false,
		"setup": [{"step": "object_rows", "seed_offset": 3, "rows": [
			{"name": "chairs", "anchor": "clearing_top", "offset": -1, "objects": [{"kind": "chair", "count": 2}]}]}],
	}]}})
	var registry := ContentRegistryType.new(BASE, SCHEMAS, [PACK_DIR] as Array[String])
	_cleanup_pack()
	_expect(registry.is_valid(), "a pack adding a scenario must load: %s" % registry.get_error())
	if not registry.is_valid():
		return
	var world := ScenarioBuilderType.build(registry, "pack_camp")
	var again := ScenarioBuilderType.build(registry, "pack_camp")
	_expect(world.get_seed() == 77 and world.get_map_width() == 32 and world.get_map_height() == 32,
		"the pack scenario must use its own seed and size")
	var chairs := world.get_objects().filter(func(o: Dictionary) -> bool: return o["kind"] == "chair")
	_expect(chairs.size() == 2, "the pack scenario must place its two chairs, got %d" % chairs.size())
	_expect_same_run([world, again], "pack_camp")

func _check_registry_rejects_bad_scenarios() -> void:
	var good_step := {"step": "dig_orders", "count": 1, "seed_offset": 1, "priority": 1}
	var cases := [
		[{"step": "per_colonist_objects", "kind": "no_such_object"}, true, ContentRegistryType.ERROR_DANGLING_REFERENCE, "an unknown object kind"],
		[{"step": "ground_items", "kind": "no_such_item", "count": 1, "search_radius": 1}, true, ContentRegistryType.ERROR_DANGLING_REFERENCE, "an unknown item kind"],
		[{"step": "object_rows", "seed_offset": 1, "rows": [{"name": "r", "anchor": "clearing_top", "offset": 0, "door": "no_such_door",
			"objects": [{"kind": "chair", "count": 1}]}]}, true, ContentRegistryType.ERROR_DANGLING_REFERENCE, "an unknown door kind"],
		[{"step": "dig_orders", "count": 1, "seed_offset": 1}, true, ContentRegistryType.ERROR_SCHEMA_VIOLATION, "a step missing a field it reads"],
		[good_step.merged({"kind": "chair"}), true, ContentRegistryType.ERROR_SCHEMA_VIOLATION, "a step carrying a field it does not read"],
		[{"step": "no_such_step"}, true, ContentRegistryType.ERROR_SCHEMA_VIOLATION, "an unknown step"],
		[good_step.merged({"when": "scenario_seed"}), false, ContentRegistryType.ERROR_SCHEMA_VIOLATION, "a seed-gated step in a scenario with no seed"],
	]
	for case: Array in cases:
		var scenario := {"id": "bad", "label": "Bad", "tick_rate": 10, "incidents_enabled": false, "setup": [case[0]]}
		if case[1]:
			scenario["seed"] = 1
		_write_pack({"scenarios": {"scenarios": [scenario]}})
		var registry := ContentRegistryType.new(BASE, SCHEMAS, [PACK_DIR] as Array[String])
		_cleanup_pack()
		var what := String(case[3])
		_expect(not registry.is_valid(), "%s must fail construction" % what)
		var error := registry.get_error()
		_expect(error.get("code") == case[2], "%s must fail with %s, got %s" % [what, case[2], error])
		_expect(String(error.get("file", "")).ends_with("scenarios.json"), "%s must name scenarios.json, got %s" % [what, error])
		_expect(registry.list("scenarios").is_empty(), "%s must expose no partial bundle" % what)

func _check_unknown_scenario_or_missing_seed_builds_nothing() -> void:
	_expect(ScenarioBuilderType.build(_content, "no_such_scenario") == null, "an unknown scenario must build nothing")
	_expect(ScenarioBuilderType.build(_content, "new_game") == null, "new_game has no seed, so a build without one must build nothing")

func _check_dialog_picks_the_scenario_boot_builds() -> void:
	var dialog := NewGameDialogType.new()
	dialog.set_scenarios(_content.list("scenarios"))
	var picker := dialog.scenario_picker
	_expect(picker.item_count == 2, "the dialog must list both scenarios, got %d" % picker.item_count)
	_expect(dialog.pending_scenario_id == "new_game" and picker.get_item_metadata(picker.selected) == "new_game",
		"the dialog must preselect new_game")
	var debug_index := -1
	for i in picker.item_count:
		if picker.get_item_metadata(i) == "debug":
			debug_index = i
	picker.select(debug_index)
	picker.item_selected.emit(debug_index)
	_expect(dialog.pending_scenario_id == "debug", "picking the debug item must set pending_scenario_id")
	dialog.free()
	var picked := BootType.build_default_world(7, 10, _content, "debug")
	_expect(picked.get_seed() == 7 and picked.get_map_width() == 48, "boot must build the picked scenario with the dialog's seed")
	_expect(picked.state_hash() == DebugScenarioType.build(7, 10, true).state_hash(),
		"boot's debug build with seed 7 must match DebugScenario's with incidents on")

func _expect_same_run(worlds: Array, what: String) -> void:
	var reference: WorldStateType = worlds[0]
	for world: WorldStateType in worlds:
		_expect(world.state_hash() == reference.state_hash(), "%s must hash alike at build time" % what)
	for i in TRACE_TICKS:
		for world: WorldStateType in worlds:
			world.tick()
	for world: WorldStateType in worlds:
		_expect(world.state_hash() == reference.state_hash(), "%s must hash alike after %d ticks" % [what, TRACE_TICKS])

func _count_tiles(world: WorldStateType, tile_id: String) -> int:
	return world.get_tiles().count(tile_id)

func _seed_stock(world: WorldStateType) -> int:
	var total := 0
	for item: Dictionary in world.get_items():
		if item["kind"] == "seed":
			total += int(item["count"])
	return total

func _write_pack(files: Dictionary) -> void:
	_cleanup_pack()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PACK_DIR))
	_write_json(PACK_DIR + "/pack.json", {"id": "scenario_pack", "version": "1"})
	for kind: String in files:
		_write_json("%s/%s.json" % [PACK_DIR, kind], files[kind])

func _write_json(path: String, value: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(value))
	file.close()

func _cleanup_pack() -> void:
	var dir := DirAccess.open(PACK_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir():
			dir.remove(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PACK_DIR))
