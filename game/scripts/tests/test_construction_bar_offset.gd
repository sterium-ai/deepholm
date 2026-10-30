extends SceneTree

## B4: a construction site's progress bar sits just above its footprint's top edge, as
## wide as the footprint, at the same offset for every kind and both workbench
## orientations. The bar used to be placed a whole tile above the ghost sprite's top, so
## it floated higher the taller the sprite was. Builds real sites with `build` commands
## and reads them back through get_construction_sites(), the record map_view.gd draws.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")

const SEED := 424242
## The bar's intended geometry, written here as literals rather than read from map_view.gd's
## constants, so moving or resizing the bar in production fails this test.
const EXPECTED_GAP := 1.0
const EXPECTED_HEIGHT := 3.0
const SPECS := [
	["wooden_wall", "", Vector2i(1, 1)],
	["stone_wall", "", Vector2i(1, 1)],
	["door", "", Vector2i(1, 1)],
	["bed", "", Vector2i(1, 1)],
	["workbench", "horizontal", Vector2i(2, 1)],
	["workbench", "vertical", Vector2i(1, 2)],
]

var _failed := false

func _init() -> void:
	var world := WorldStateType.new(SEED)
	var row := _free_soil_row(world, 3 * SPECS.size())
	_expect(row != Vector2i(-1, -1), "fixture map must have a free soil row for the sites")
	if row != Vector2i(-1, -1):
		_check_bars(world, row)
	if _failed:
		quit(1)
		return
	print("test_construction_bar_offset: PASS")
	quit(0)

func _check_bars(world: WorldStateType, row: Vector2i) -> void:
	var expected_size := {}
	for i in SPECS.size():
		var origin := row + Vector2i(3 * i, 0)
		var result: Dictionary = world.apply({"actor": "test", "command_id": "site_%d" % i,
			"tick": world.get_tick(), "type": "build",
			"payload": {"kind": SPECS[i][0], "x": origin.x, "y": origin.y, "z": 0, "orientation": SPECS[i][1]}})
		_expect(bool(result.get("ok", false)), "build %s %s must be accepted: %s" % [SPECS[i][0], SPECS[i][1], result])
		expected_size[origin] = SPECS[i][2]
	var sites := world.get_construction_sites()
	_expect(sites.size() == SPECS.size(), "expected %d sites, got %d" % [SPECS.size(), sites.size()])
	var tile := MapViewType.TILE_SIZE
	for site in sites:
		var site_origin: Vector3i = site["origin"]
		var origin := Vector2i(site_origin.x, site_origin.y)
		var label := "%s %s at %s" % [site["kind"], site.get("orientation", ""), origin]
		var footprint := MapViewType.construction_site_footprint_rect(site)
		_expect(footprint == Rect2(Vector2(origin) * tile, Vector2(expected_size.get(origin, Vector2i.ONE)) * tile),
			"%s: footprint rect must cover its own tiles, got %s" % [label, footprint])
		var bar := MapViewType.construction_bar_rect(footprint)
		_expect(is_equal_approx(bar.end.y, footprint.position.y - EXPECTED_GAP),
			"%s: bar must end %s px above the footprint top (%s), got bar %s" % [label, EXPECTED_GAP, footprint.position.y, bar])
		_expect(is_equal_approx(bar.position.x, footprint.position.x) and is_equal_approx(bar.size.x, footprint.size.x),
			"%s: bar must span exactly the footprint's width, got bar %s for footprint %s" % [label, bar, footprint])
		_expect(is_equal_approx(bar.size.y, EXPECTED_HEIGHT), "%s: bar must be %s px high, got %s" % [label, EXPECTED_HEIGHT, bar.size.y])

## The leftmost tile of a horizontal run of `length` free soil tiles whose row below is
## free soil too (the vertical workbench covers it).
func _free_soil_row(world: WorldStateType, length: int) -> Vector2i:
	for y in range(1, world.get_map_height() - 1):
		for x in range(0, world.get_map_width() - length):
			var ok := true
			for i in length:
				for dy in 2:
					if world.get_tile(x + i, y + dy) != WorldStateType.TILE_SOIL or world.get_object(x + i, y + dy) != "":
						ok = false
			if ok:
				return Vector2i(x, y)
	return Vector2i(-1, -1)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)
