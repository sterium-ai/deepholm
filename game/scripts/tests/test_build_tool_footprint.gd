extends SceneTree

const WorldStateType = preload("res://scripts/core/world_state.gd")
const BootType = preload("res://scripts/boot.gd")

var _failed := false

func _init() -> void:
	var world := WorldStateType.new(408, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	var boot := BootType.new()
	root.add_child(boot)
	boot.world = world
	var map_view = preload("res://scripts/viewer/map_view.gd").new()
	boot._map_view = map_view
	map_view.set_world(world)
	boot._select_tool(BootType.Tool.BUILD_WORKBENCH)
	map_view.set_build_rotatable(true)

	var horizontal: Dictionary = boot._command_for_tile(BootType.Tool.BUILD_WORKBENCH, Vector2i(10, 10))
	_expect(horizontal["payload"]["orientation"] == "horizontal", "workbench starts horizontal")
	_expect(world.preview(horizontal).get("ok", false), "horizontal workbench preview is valid")
	map_view.toggle_build_orientation()
	var vertical: Dictionary = boot._command_for_tile(BootType.Tool.BUILD_WORKBENCH, Vector2i(10, 10))
	_expect(vertical["payload"]["orientation"] == "vertical", "rotate toggles workbench to vertical")
	_expect(world.preview(vertical).get("ok", false), "vertical workbench preview is valid")
	var placed := world.apply(vertical)
	_expect(placed.get("ok", false), "vertical workbench build is accepted")
	_expect(world.get_construction_site(10, 10).get("id", "") == placed.get("site_id", ""), "origin resolves construction site")
	_expect(world.get_construction_site(10, 11).get("id", "") == placed.get("site_id", ""), "second vertical footprint tile resolves construction site")
	var invalid := boot._preview_validity([Vector2i(10, 47), Vector2i(10, 48)])
	_expect(invalid == [false, false], "out-of-bounds workbench footprint previews both tiles red")
	var cancel := boot._command_for_tile(BootType.Tool.CANCEL, Vector2i(10, 11))
	_expect(cancel.get("type", "") == "cancel_site", "cancel on any footprint tile uses cancel_site")
	_expect(world.apply(cancel).get("ok", false), "cancel_site over second footprint tile is accepted")

	map_view.free()
	root.remove_child(boot)
	boot.free()
	if _failed:
		quit(1)
		return
	print("test_build_tool_footprint: PASS")
	quit(0)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		_failed = true
