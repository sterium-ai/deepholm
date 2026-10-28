extends SceneTree

## ADR 051: a work kind's completion effect is its jobs.json "effects" block, applied by
## ToilBindings.apply_work_effects() with no per-kind code. A fixture bundle (the real
## content plus two kinds no code names, "quarry" and "press") loads through ContentRegistry,
## and its blocks drive the TileGrid, ObjectTable and ItemTable of a world built on that
## registry (A13's session registry): tile check, input consumed, tile transform, object cleared, yields at
## both placements, ground berries, and a staged find resolved by resolve_dig_finds().
## Also checks the registry's effects cross-checks (unknown tile/item, no work toil, bad
## placement) and that the six real work kinds declare their effects.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const ToilBindingsType = preload("res://scripts/core/jobs/toil_bindings.gd")

const FIXTURE_DIR := "user://test-work-effects-content-fixture"

const QUARRY := '{"kind": "quarry", "labour": "mine", "toils": ["reserve", "go_to", "work", "release_all"], "work_ticks": 10, "effects": {"requires_tile": "rock", "set_tile": "floor", "clear_object": true, "yields": {"placement": "adjacent", "always": ["stone", "flint"], "find_table": [{"item": "coal", "weight": 100}]}}}'
const PRESS := '{"kind": "press", "labour": "farm", "toils": ["reserve", "go_to", "work", "release_all"], "work_ticks": 5, "effects": {"requires_tile": "floor", "consumes": "seed", "set_tile": "planted", "yields": {"placement": "target", "ground_berries": 2}}}'

var _failed := false

func _init() -> void:
	_check_real_work_kinds_declare_effects()
	_check_new_kind_from_content_only()
	_check_effects_cross_checks()
	if _failed:
		quit(1)
		return
	print("test_work_effects_content: PASS")
	quit(0)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

## dig, chop, mine, forage, till and sow have no completion branch in ToilBindings any more,
## so each must carry its effects block, with the tiles and items it always had.
func _check_real_work_kinds_declare_effects() -> void:
	var registry := ContentRegistryType.new()
	_expect(registry.is_valid(), "the real content bundle must load: %s" % registry.get_error())
	var expected := {
		"dig": {"requires_tile": "soil", "set_tile": "trench", "placement": "adjacent", "always": ["sand"]},
		"mine": {"requires_tile": "rock", "set_tile": "floor", "placement": "target", "always": ["stone"]},
		"chop": {"set_tile": "soil", "placement": "target", "always": ["wood"]},
		"forage": {"set_tile": "floor", "placement": "target", "ground_berries": 1},
		"till": {"requires_tile": "soil", "set_tile": "plowed_soil"},
		"sow": {"requires_tile": "plowed_soil", "consumes": "seed", "set_tile": "planted"},
	}
	for kind in expected:
		var effects: Dictionary = registry.get_entry("jobs", kind).get("effects", {})
		var want: Dictionary = expected[kind]
		var yields: Dictionary = effects.get("yields", {})
		for field in ["requires_tile", "set_tile", "consumes"]:
			_expect(String(effects.get(field, "")) == String(want.get(field, "")),
				"%s effects.%s must be '%s', got %s" % [kind, field, want.get(field, ""), effects])
		_expect(String(yields.get("placement", "")) == String(want.get("placement", "")),
			"%s yields.placement must be '%s', got %s" % [kind, want.get("placement", ""), effects])
		_expect((yields.get("always", []) as Array) == (want.get("always", []) as Array),
			"%s yields.always must be %s, got %s" % [kind, want.get("always", []), effects])
		_expect(int(yields.get("ground_berries", 0)) == int(want.get("ground_berries", 0)),
			"%s yields.ground_berries must be %d, got %s" % [kind, want.get("ground_berries", 0), effects])
	_expect(bool(registry.get_entry("jobs", "forage")["effects"].get("clear_object", false)), "forage must clear its bush")
	_expect(registry.get_entry("jobs", "dig")["effects"]["yields"].has("find_table"), "dig keeps its find_table")

func _check_new_kind_from_content_only() -> void:
	_write_fixture(",\n    " + QUARRY + ",\n    " + PRESS)
	var registry := ContentRegistryType.new(FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)
	_cleanup_fixture()
	_expect(registry.is_valid(), "the fixture with two new work kinds must load: %s" % registry.get_error())
	if not registry.is_valid():
		return
	# A13: the world is built on the fixture as its session registry, so its own ItemTable
	# reads the fixture kinds' effects.
	var world := WorldStateType.new(7, 10, 12, 12, false, registry)
	var grid = world._tile_grid
	var objects = world._object_table
	var items = world._item_table
	world._colonists.clear()
	grid.tiles.fill(WorldStateType.TILE_FLOOR)
	objects.objects.clear()
	objects.object_factions.clear()
	items.items.clear()
	items.item_factions.clear()
	var rng: RandomNumberGenerator = items.dig_find_random

	# quarry at (3, 3): rock with a bush on it; its north neighbour is rock, so the first
	# passable non-trench neighbour (N, W, E, S) is the west one, (2, 3).
	var target := Vector2i(3, 3)
	grid.tiles[grid.tile_index(3, 3)] = WorldStateType.TILE_ROCK
	grid.tiles[grid.tile_index(3, 2)] = WorldStateType.TILE_ROCK
	objects.set_object(3, 3, "berry_bush")
	var quarry: Dictionary = items.work_effects("quarry")
	_expect(not quarry.is_empty(), "ItemTable must expose the fixture kind's effects block")
	var refusal: Dictionary = ToilBindingsType.apply_work_effects(quarry, "job_7", "quarry", target, grid, objects, items)
	_expect(refusal.is_empty(), "quarry on rock must apply, got %s" % refusal)
	_expect(grid.get_tile(3, 3) == WorldStateType.TILE_FLOOR, "quarry must turn rock into floor, got %s" % grid.get_tile(3, 3))
	_expect(objects.get_object(3, 3) == "", "quarry must clear the object on its tile")
	var kinds_at := _kinds_at(items, Vector2i(2, 3))
	_expect(kinds_at == ["stone", "flint"], "quarry's always yields land adjacent, in list order, got %s" % [items.get_items()])
	_expect(items.items.size() == 2, "only the two always yields exist before the find resolves, got %s" % [items.get_items()])
	_expect(items.pending_dig_finds == [{"job_id": "job_7", "kind": "quarry", "x": 3, "y": 3}],
		"quarry must stage one find of its own kind, got %s" % [items.pending_dig_finds])
	var rng_state := rng.state
	items.resolve_dig_finds()
	_expect(rng.state != rng_state, "resolving the find must draw from the find stream")
	_expect(items.pending_dig_finds.is_empty(), "resolve_dig_finds() must drain the staged find")
	_expect(_kinds_at(items, Vector2i(2, 3)) == ["stone", "flint", "coal"], "quarry's find (coal, weight 100) lands adjacent, got %s" % [items.get_items()])

	# A second quarry on the same tile finds floor: refused, nothing changes.
	var before: Array = items.get_items()
	refusal = ToilBindingsType.apply_work_effects(quarry, "job_8", "quarry", target, grid, objects, items)
	_expect(refusal == {"reason": "invalid_target", "remedy": "resubmit_order"}, "a quarry on floor must be refused invalid_target, got %s" % refusal)
	_expect(items.get_items() == before and items.pending_dig_finds.is_empty(), "a refused quarry must change nothing")

	# press at (6, 6): consumes one seed; without one it is refused and the tile stays floor.
	var press: Dictionary = items.work_effects("press")
	var press_at := Vector2i(6, 6)
	refusal = ToilBindingsType.apply_work_effects(press, "job_9", "press", press_at, grid, objects, items)
	_expect(refusal == {"reason": "blocked_missing_input", "remedy": "resubmit_order"}, "a press with no seed must be refused blocked_missing_input, got %s" % refusal)
	_expect(grid.get_tile(6, 6) == WorldStateType.TILE_FLOOR, "a refused press must leave the tile")
	items.place_new_ground_item("seed", 2, 0, 0)
	refusal = ToilBindingsType.apply_work_effects(press, "job_10", "press", press_at, grid, objects, items)
	_expect(refusal.is_empty(), "a press with a seed on the ground must apply, got %s" % refusal)
	_expect(grid.get_tile(6, 6) == WorldStateType.TILE_PLANTED, "press must plant its tile")
	_expect(items.get_ground_berries(6, 6) == 2, "press yields two ground berries at its target, got %d" % items.get_ground_berries(6, 6))
	_expect(_kinds_at(items, Vector2i(0, 0)) == ["seed"] and int(items.get_items().filter(func(i: Dictionary) -> bool: return i["kind"] == "seed")[0]["count"]) == 1,
		"press must consume exactly one seed, got %s" % [items.get_items()])
	_expect(items.pending_dig_finds.is_empty(), "a kind without a find_table stages no find")

func _check_effects_cross_checks() -> void:
	var cases := [
		{"name": "unknown set_tile", "entry": QUARRY.replace('"set_tile": "floor"', '"set_tile": "lava"'),
			"code": ContentRegistryType.ERROR_DANGLING_REFERENCE, "mentions": "lava"},
		{"name": "unknown requires_tile", "entry": QUARRY.replace('"requires_tile": "rock"', '"requires_tile": "magma"'),
			"code": ContentRegistryType.ERROR_DANGLING_REFERENCE, "mentions": "magma"},
		{"name": "unknown always item", "entry": QUARRY.replace('"flint"', '"opal"'),
			"code": ContentRegistryType.ERROR_DANGLING_REFERENCE, "mentions": "opal"},
		{"name": "unknown consumed item", "entry": PRESS.replace('"consumes": "seed"', '"consumes": "grain"'),
			"code": ContentRegistryType.ERROR_DANGLING_REFERENCE, "mentions": "grain"},
		{"name": "unknown find item", "entry": QUARRY.replace('"coal"', '"amber"'),
			"code": ContentRegistryType.ERROR_DANGLING_REFERENCE, "mentions": "amber"},
		{"name": "no work toil", "entry": QUARRY.replace('"go_to", "work", ', '"go_to", '),
			"code": ContentRegistryType.ERROR_SCHEMA_VIOLATION, "mentions": "work"},
		{"name": "bad placement", "entry": QUARRY.replace('"adjacent"', '"sideways"'),
			"code": ContentRegistryType.ERROR_SCHEMA_VIOLATION, "mentions": "placement"},
		{"name": "missing placement", "entry": PRESS.replace('"placement": "target", ', ''),
			"code": ContentRegistryType.ERROR_SCHEMA_VIOLATION, "mentions": "placement"},
		{"name": "find weights not 100", "entry": QUARRY.replace('"weight": 100', '"weight": 90'),
			"code": ContentRegistryType.ERROR_SCHEMA_VIOLATION, "mentions": "sum to 100"},
	]
	for case in cases:
		_write_fixture(",\n    " + String(case["entry"]))
		var registry := ContentRegistryType.new(FIXTURE_DIR, ContentRegistryType.DEFAULT_SCHEMA_DIR)
		_cleanup_fixture()
		var error := registry.get_error()
		_expect(not registry.is_valid(), "%s must fail construction" % case["name"])
		_expect(error.get("code") == case["code"], "%s must be typed %s, got %s" % [case["name"], case["code"], error])
		_expect(String(error.get("file", "")).ends_with("jobs.json"), "%s must name jobs.json, got %s" % [case["name"], error])
		_expect(String(error.get("message", "")).contains(String(case["mentions"])), "%s must mention '%s', got %s" % [case["name"], case["mentions"], error])

## Item kinds on tile, in id order.
func _kinds_at(items, tile: Vector2i) -> Array:
	var kinds: Array = []
	for item in items.get_items():
		if int(item["x"]) == tile.x and int(item["y"]) == tile.y:
			kinds.append(item["kind"])
	return kinds

## Copies every res://content/*.json file as text (the registry's own parser keeps integers;
## a JSON round trip through Godot would turn them into floats) and appends extra_jobs to
## jobs.json's array.
func _write_fixture(extra_jobs: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FIXTURE_DIR))
	for file_name in DirAccess.get_files_at(ContentRegistryType.DEFAULT_CONTENT_DIR):
		if not file_name.ends_with(".json"):
			continue
		var text := FileAccess.get_file_as_string(ContentRegistryType.DEFAULT_CONTENT_DIR + file_name)
		if file_name == "jobs.json":
			var close := text.rfind("]")
			text = text.substr(0, close).strip_edges(false, true) + extra_jobs + "\n  " + text.substr(close)
		var file := FileAccess.open(FIXTURE_DIR + "/" + file_name, FileAccess.WRITE)
		file.store_string(text)
		file.close()

func _cleanup_fixture() -> void:
	for file_name in DirAccess.get_files_at(FIXTURE_DIR):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(FIXTURE_DIR + "/" + file_name))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(FIXTURE_DIR))
