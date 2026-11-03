extends SceneTree

## L4 capture (handoff evidence, not shipped). Run: Godot --path game --script <this file> -- <out dir> <label>: the two-layer fixture of test_viewer_active_layer.gd,
## drawn by MapView (pack art when present), saved per layer. Before L4 the viewer has no
## set_active_layer(), so it captures only what it draws (the surface).
const WorldStateType = preload("res://scripts/core/world_state.gd")
const MapViewType = preload("res://scripts/viewer/map_view.gd")
const SIZE := 16

func _init() -> void:
	var out: String = OS.get_cmdline_user_args()[0]
	var label: String = OS.get_cmdline_user_args()[1]
	root.size = Vector2i(SIZE * 16 * 3, SIZE * 16 * 3)
	var state := WorldStateType.new(451_002, 10, SIZE, SIZE).to_save_state()
	state["map"]["layerCount"] = 2
	var deep: Array = []
	for y in SIZE:
		for x in SIZE:
			deep.append(WorldStateType.TILE_FLOOR if x >= 2 and x <= 5 and y >= 2 and y <= 5 else WorldStateType.TILE_ROCK)
	(state["map"]["tiles"] as Array).append_array(deep)
	for entity: Dictionary in state["entities"]:
		if String(entity.get("kind", "")) == "colonist":
			entity["x"] = 3
			entity["y"] = 3
			entity["z"] = 1
			break
	var world = WorldStateType.from_save_state(state)
	var map_view := MapViewType.new()
	map_view.scale = Vector2(3, 3)
	root.add_child(map_view)
	map_view.set_world(world)
	var layers := [0, 1] if map_view.has_method("set_active_layer") else [0]
	for z in layers:
		if z > 0:
			map_view.set_active_layer(z)
		map_view.queue_redraw()
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		var err := root.get_texture().get_image().save_png(out.path_join("%s-z%d.png" % [label, z]))
		print("saved %s z%d: %d" % [label, z, err])
	quit(0)
