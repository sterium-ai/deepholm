extends Control

const PENDING_PAN_DEAD_ZONE := 4.0

## Camera state belongs only to presentation. The child's transform is also
## the sole input conversion, so rendering and designation cannot drift.
var map_view: Control
var zoom_level := 1.0
var _pan_button := 0
var _pending_pan := false
var _pending_pan_position := Vector2.ZERO
var _space_down := false

func _init() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(_constrain)
	mouse_exited.connect(func():
		if map_view != null:
			map_view.clear_hover())

func attach(view: Control) -> void:
	map_view = view
	map_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(map_view)
	_constrain()

func screen_to_world(screen_position: Vector2) -> Vector2:
	return map_view.get_global_transform_with_canvas().affine_inverse() * screen_position

func screen_to_tile(screen_position: Vector2) -> Vector2i:
	return map_view.tile_at_local(screen_to_world(screen_position))

func zoom_at(local_position: Vector2, requested_zoom: float) -> void:
	var anchor := screen_to_world(get_global_transform_with_canvas() * local_position)
	zoom_level = clampf(requested_zoom, 0.5, 3.0)
	map_view.scale = Vector2.ONE * zoom_level
	map_view.position = local_position - anchor * zoom_level
	_constrain()

func pan_by(delta: Vector2) -> void:
	map_view.position += delta
	_constrain()

func center_colonists() -> void:
	cancel_gesture()
	var center := map_view.size * 0.5
	var colonists: Array = map_view.world.get_colonists()
	if not colonists.is_empty():
		center = Vector2.ZERO
		for colonist in colonists:
			center += (Vector2(colonist["x"], colonist["y"]) + Vector2.ONE * 0.5) * map_view.TILE_SIZE
		center /= colonists.size()
	map_view.position = size * 0.5 - center * zoom_level
	_constrain()

func cancel_gesture() -> void:
	_pan_button = 0
	_pending_pan = false
	map_view.cancel_selection()

func _constrain() -> void:
	if map_view == null:
		return
	var extent := map_view.size * zoom_level
	for axis in 2:
		map_view.position[axis] = (size[axis] - extent[axis]) * 0.5 if extent[axis] <= size[axis] else clampf(map_view.position[axis], size[axis] - extent[axis], 0.0)

func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		if event.keycode == KEY_SPACE:
			_space_down = event.pressed
			# Space is a camera modifier, even if a toolbar button has focus.
			get_viewport().set_input_as_handled()
		if event.keycode == KEY_ESCAPE and event.pressed:
			_pan_button = 0
			_pending_pan = false
			map_view.leave_tool()
			get_viewport().set_input_as_handled()
	# Releases over HUD must abort, never complete an order there. The normal
	# GUI release inside the map still commits through _gui_input below.
	if event is InputEventMouseButton and not event.pressed:
		if not get_global_rect().has_point(event.position):
			map_view.cancel_selection()
			_pan_button = 0
			_pending_pan = false

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and map_view != null:
		_space_down = false
		cancel_gesture()

func _gui_input(event: InputEvent) -> void:
	if map_view == null:
		return
	if event is InputEventMouseButton:
		if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			if event.pressed:
				cancel_gesture()
				zoom_at(event.position, zoom_level * (1.2 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.2))
			accept_event()
			return
		if event.pressed and (event.button_index == MOUSE_BUTTON_MIDDLE or (event.button_index == MOUSE_BUTTON_LEFT and _space_down)):
			map_view.cancel_selection()
			_pan_button = event.button_index
			_pending_pan = false
			accept_event()
			return
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT and not map_view.tool_enabled and not _space_down:
			_pending_pan = true
			_pending_pan_position = event.position
		if not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_pending_pan = false
		if _pan_button != 0:
			if not event.pressed and event.button_index == _pan_button:
				_pan_button = 0
				_pending_pan = false
			accept_event()
			return
	if event is InputEventMouseMotion:
		if _pending_pan:
			if event.position.distance_to(_pending_pan_position) > PENDING_PAN_DEAD_ZONE:
				_pending_pan = false
				map_view.cancel_selection()
				_pan_button = MOUSE_BUTTON_LEFT
				pan_by(event.relative)
				accept_event()
				return
		elif _pan_button != 0:
			pan_by(event.relative)
			accept_event()
			return
	if event is InputEventMouse:
		if not Rect2(Vector2.ZERO, size).has_point(event.position):
			map_view.clear_hover()
			return
		var converted := event.duplicate() as InputEventMouse
		converted.position = screen_to_world(get_global_transform_with_canvas() * event.position)
		map_view._gui_input(converted)
		accept_event()
